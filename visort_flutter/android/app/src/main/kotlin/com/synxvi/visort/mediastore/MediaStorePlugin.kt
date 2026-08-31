package com.synxvi.visort.mediastore

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// ───────────────────────── MediaStore MethodChannel 入口 ─────────────────────────
//
// 对接 Dart 侧 AndroidMediaStoreFileSystem。
// channel: "visort/mediastore"
// events channel: "visort/mediastore-events"（ContentObserver 变更通知）
//
// 方法：
//   listBuckets()               → 列出所有相册（id/name/count）
//   scanImages(bucketIds, cursor) → 按相册扫描一页图片（keyset 分页）
//   readMeta(id)                → 单图元信息
//   readBytes(id, maxBytes)     → 读字节
//   readThumbnail(id, w, h)     → 缩略图字节
//   exists(id)                  → 存在性
//   requestDelete(ids)          → 批量删除（系统弹窗确认）
//   requestMove(ids, relPath)   → 批量改 RELATIVE_PATH
//   getBucketRelativePath(id)   → 查相册 RELATIVE_PATH
//   hasPermission()             → 检查 READ_MEDIA_IMAGES
//   requestPermission()         → 请求 READ_MEDIA_IMAGES
//   hasManageMedia()            → 检查 MANAGE_MEDIA 特殊权限
//   requestManageMedia()        → 跳转媒体管理设置
//
// 关键机制：
//   1. ActivityAware 管理生命周期
//   2. ActivityResultListener 处理 createDeleteRequest/createWriteRequest 系统弹窗回调
//   3. RequestPermissionsResultListener 处理权限请求回调
//   4. EventChannel + ContentObserver：图库增删时主动通知 Dart 端刷新

private const val CHANNEL = "visort/mediastore"
private const val EVENTS_CHANNEL = "visort/mediastore-events"
private const val TAG = "MsPlugin"

private const val REQUEST_DELETE = 0x4D53 // "MS"
private const val REQUEST_MOVE = 0x4D56 // "MV"
private const val REQUEST_PERMISSION = 0x5045 // "PE"
private const val REQUEST_FAVORITE = 0x4641 // "FA"
private const val REQUEST_TRASH = 0x5452 // "TR"
private const val REQUEST_RESTORE = 0x5253 // "RS"
private const val REQUEST_RENAME = 0x524E // "RN"

class MediaStorePlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var mediaObserver: ContentObserver? = null
    private var binding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var repository: MediaStoreRepository? = null

    /// 应用级 context（engine 附着期存续，比 activity 生命周期长）——
    /// WorkManager 调度入口用它（后台任务不依赖 Activity 存在）。
    private var appContext: Context? = null

    /// IO 线程池：图片字节/缩略图/查询放后台，避免阻塞 UI 线程导致滚动卡顿。
    /// 12 线程 = 对标系统相册 BaseThumbnailLoader 的 12 并发上限——
    /// 首屏 20+ 张缩略图 4 线程要排 5 轮（每轮 loadThumbnail 首次生成 50~200ms），
    /// 12 线程 2 轮内发完，首屏时间减半以上。
    private val ioExecutor = Executors.newFixedThreadPool(12)
    /// 回主线程回调 MethodChannel.Result（result 必须在主线程调用）
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 待处理的删除请求（弹窗是异步的）
    private var pendingDeleteResult: Result? = null
    private var pendingDeleteCount: Int = 0

    /// 待处理的移动请求（弹窗是异步的）
    private var pendingMoveResult: Result? = null
    private var pendingMoveIds: List<String> = emptyList()
    private var pendingMoveRelativePath: String = ""
    /// 弹窗发起前已直移成功的自有文件 id 集（部分成功契约，见 MoveResult）
    private var pendingMoveAlreadyMoved: List<String> = emptyList()
    /// 删除弹窗发起前的 MANAGE_MEDIA 直删数 / 弹窗涉及的 URI 数（契约同上）
    private var pendingDeleteDirectCount: Int = 0
    private var pendingDeleteConsentCount: Int = 0
    /// 弹窗删除的完整 ids（成功/部分成功分支据此清磁盘缓存文件）。
    private var pendingDeleteIds: List<String> = emptyList()

    /// 待处理的重命名请求（他人文件授权弹窗异步）
    private var pendingRenameResult: Result? = null
    private var pendingRenameId: String = ""
    private var pendingRenameNewName: String = ""

    /// 待处理的权限请求
    private var pendingPermissionResult: Result? = null

    /// 待处理的收藏请求（弹窗异步，P1b）
    private var pendingFavoriteResult: Result? = null

    /// 待处理的回收站/恢复请求（弹窗异步，P1a）
    private var pendingTrashResult: Result? = null
    private var pendingRestoreResult: Result? = null

    // ──────────── FlutterPlugin 生命周期 ────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        val resolver = binding.applicationContext.contentResolver
        // EventChannel：ContentObserver 变更通知。Dart 订阅后图库变化收到结构化事件，
        // 触发精准增量刷新（P1c：insert/update/delete + id/bucketId）。
        val streamHandler = MediaChangeStreamHandler(resolver)
        eventChannel = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(streamHandler)
        }
        // 注册 ContentObserver 监听 MediaStore.Images 变化。
        // observer 回调绑定到 mainHandler（主线程），收到变更时带 uri 转发给 streamHandler 分类。
        mediaObserver = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean, uri: android.net.Uri?) {
                streamHandler.notifyChanged(uri)
            }
        }.also { observer ->
            // notifyForDescendants=true：子 URI（单图）变更也通知，确保删图能被捕获
            resolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer
            )
        }
        Log.i(TAG, "MediaStorePlugin 已附加（channel=$CHANNEL, events=$EVENTS_CHANNEL）")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // 注销 ContentObserver
        appContext = null
        mediaObserver?.let { binding.applicationContext.contentResolver.unregisterContentObserver(it) }
        mediaObserver = null
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        ioExecutor.shutdownNow()
    }

    // ──────────── ActivityAware 生命周期 ────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        this.activity = binding.activity
        repository = MediaStoreRepository(activity!!.applicationContext)
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
        Log.i(TAG, "已绑定 Activity")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        cleanupBinding()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        cleanupBinding()
    }

    private fun cleanupBinding() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
        repository = null
        // 六个 pending 全部补齐并回 error：只置 null 会让 Dart 侧 await 的
        // Future 永久挂起（系统弹窗期间 Activity 被 detach/重建的场景）。
        // DETACHED 走 error 而非 success，Dart catch 后按失败处理可重试。
        pendingDeleteResult?.error("DETACHED", "Activity 已分离", null)
        pendingDeleteResult = null
        pendingPermissionResult?.error("DETACHED", "Activity 已分离", null)
        pendingPermissionResult = null
        pendingRenameResult?.error("DETACHED", "Activity 已分离", null)
        pendingRenameResult = null
        pendingMoveResult?.error("DETACHED", "Activity 已分离", null)
        pendingMoveResult = null
        pendingMoveIds = emptyList()
        pendingMoveRelativePath = ""
        pendingMoveAlreadyMoved = emptyList()
        pendingDeleteDirectCount = 0
        pendingDeleteConsentCount = 0
        pendingFavoriteResult?.error("DETACHED", "Activity 已分离", null)
        pendingFavoriteResult = null
        pendingTrashResult?.error("DETACHED", "Activity 已分离", null)
        pendingTrashResult = null
        pendingRestoreResult?.error("DETACHED", "Activity 已分离", null)
        pendingRestoreResult = null
    }

    // ──────────── ActivityResult 回调（删除弹窗） ────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQUEST_DELETE -> {
                Log.i(TAG, "onActivityResult REQUEST_DELETE: resultCode=$resultCode (OK=${Activity.RESULT_OK}), pending=${pendingDeleteResult != null})")
                val pending = pendingDeleteResult ?: return true
                pendingDeleteResult = null
                if (resultCode == Activity.RESULT_OK) {
                    // minSdk 30：createDeleteRequest 授权即系统直删。
                    // 实际删除数 = 弹窗前 MANAGE_MEDIA 直删数 + 弹窗 URI 数
                    //（部分直删 + 弹窗的组合下，旧协议只报 ids.size 或取消，
                    // 已直删部分被误报/丢失——本地列表残留幽灵条目）。
                    clearImageCacheFilesAsync(pendingDeleteIds)
                    pendingDeleteIds = emptyList()
                    pending.success(pendingDeleteDirectCount + pendingDeleteConsentCount)
                } else if (pendingDeleteDirectCount > 0) {
                    // 用户取消弹窗，但直删子集已物理删除——如实上报部分
                    // 成功（Dart 侧 exists 复查会正确移除并提示部分失败），
                    // 不再抛 CANCELLED 让本地状态与磁盘脱节。
                    clearImageCacheFilesAsync(pendingDeleteIds)
                    pendingDeleteIds = emptyList()
                    pending.success(pendingDeleteDirectCount)
                } else {
                    pending.error(MsError.DeleteCancelled.code, MsError.DeleteCancelled.message, null)
                }
                return true
            }
            REQUEST_MOVE -> {
                val pending = pendingMoveResult ?: return true
                val ids = pendingMoveIds
                val relPath = pendingMoveRelativePath
                val alreadyMoved = pendingMoveAlreadyMoved
                pendingMoveResult = null
                pendingMoveIds = emptyList()
                pendingMoveRelativePath = ""
                pendingMoveAlreadyMoved = emptyList()

                if (resultCode == Activity.RESULT_OK) {
                    // 授权通过，执行真正的 update（之前 update 因权限失败只返回了 intentSender）。
                    // 全量重放是磁盘 IO，下 ioExecutor；result 回主线程。
                    val repo = repository
                    if (repo == null) {
                        pending.success(alreadyMoved)
                    } else {
                        ioExecutor.execute {
                            // 全量重放幂等（已直移的再 update 同一路径无副作用），
                            // 返回集含第一轮直移子集，无需与 alreadyMoved 合并。
                            val movedIds = repo.doMoveToRelativePath(ids, relPath)
                            mainHandler.post { pending.success(movedIds) }
                        }
                    }
                } else {
                    // 用户取消弹窗，但弹窗前直移的自有文件已物理移走——
                    // 如实返回该子集（上层据此报部分成功并同步本地状态），
                    // 不再返回空集造成"已移走却无任何反馈"的丢状态。
                    pending.success(alreadyMoved)
                }
                return true
            }
            REQUEST_FAVORITE -> {
                val pending = pendingFavoriteResult ?: return true
                pendingFavoriteResult = null
                if (resultCode == Activity.RESULT_OK) {
                    pending.success(true)
                } else {
                    pending.error(MsError.FavoriteCancelled.code, MsError.FavoriteCancelled.message, null)
                }
                return true
            }
            REQUEST_TRASH -> {
                val pending = pendingTrashResult ?: return true
                pendingTrashResult = null
                if (resultCode == Activity.RESULT_OK) {
                    pending.success(true)
                } else {
                    pending.error(MsError.TrashCancelled.code, MsError.TrashCancelled.message, null)
                }
                return true
            }
            REQUEST_RESTORE -> {
                val pending = pendingRestoreResult ?: return true
                pendingRestoreResult = null
                if (resultCode == Activity.RESULT_OK) {
                    pending.success(true)
                } else {
                    pending.error(MsError.RestoreCancelled.code, MsError.RestoreCancelled.message, null)
                }
                return true
            }
            REQUEST_RENAME -> {
                val pending = pendingRenameResult ?: return true
                val id = pendingRenameId
                val newName = pendingRenameNewName
                pendingRenameResult = null
                pendingRenameId = ""
                pendingRenameNewName = ""

                if (resultCode == Activity.RESULT_OK) {
                    // 授权通过，执行真正的 rename（同 move 的二次执行模式）。
                    // update 是磁盘 IO，下 ioExecutor；result 回主线程。
                    val repo = repository
                    if (repo == null) {
                        pending.success(0)
                    } else {
                        ioExecutor.execute {
                            val successCount = repo.doRename(id, newName)
                            mainHandler.post { pending.success(successCount) }
                        }
                    }
                } else {
                    pending.success(0) // 用户取消
                }
                return true
            }
        }
        return false
    }

    // ──────────── PermissionResult 回调 ────────────

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_PERMISSION) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null

        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
        return true
    }

    // ──────────── MethodCall 分发 ────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "listBuckets" -> handleListBuckets(call, result)
            "scanImages" -> handleScanImages(call, result)
            "detectHdrs" -> handleDetectHdrs(call, result)
            "readMeta" -> handleReadMeta(call, result)
            "getMetadata" -> handleGetMetadata(call, result)
            // 搜索索引：批量读 EXIF（拍摄时间/GPS/相机，搜索页分类数据源）。
            "indexSearchMeta" -> handleIndexSearchMeta(call, result)
            // 反地理编码：坐标 → 国家/省/市（搜索页「地点」分类）。
            "geocodePlaces" -> handleGeocodePlaces(call, result)
            "readBytes" -> handleReadBytes(call, result)
            "readThumbnail" -> handleReadThumbnail(call, result)
            "readSampledImage" -> handleReadSampledImage(call, result)
            "exists" -> handleExists(call, result)
            "requestDelete" -> handleRequestDelete(call, result)
            "getBucketRelativePath" -> handleGetBucketRelativePath(call, result)
            "requestMove" -> handleRequestMove(call, result)
            "requestRename" -> handleRequestRename(call, result)
            "requestCopy" -> handleRequestCopy(call, result)
            "nameExists" -> handleNameExists(call, result)
            "requestFavorite" -> handleRequestFavorite(call, result)
            "requestTrash" -> handleRequestTrash(call, result)
            "requestRestore" -> handleRequestRestore(call, result)
            "hasPermission" -> result.success(hasReadPermission())
            "requestPermission" -> handleRequestPermission(result)
            "openAppSettings" -> handleOpenAppSettings(result)
            "requestAccessMediaLocation" -> handleRequestAccessMediaLocation(result)
            "hasManageMedia" -> result.success(hasManageMediaPermission())
            "requestManageMedia" -> handleRequestManageMedia(result)
            // [ente 对齐] 设备总内存（MB）：解码防崩阈值用（<5GB → 24MP 上限）。
            "totalRamMb" -> handleTotalRamMb(result)
            // 空闲预缓存（全相册 screenNail 预生成，设置页档位配额）。
            "precacheFullImage" -> handlePrecacheFullImage(call, result)
            "setFullCacheQuota" -> handleSetFullCacheQuota(call, result)
            "clearImageCaches" -> handleClearImageCaches(call, result)
            "imageCacheBytes" -> handleImageCacheBytes(result)
            // WorkManager 全库预缓存（充电窗口批量补齐）+ 进度/状态查询。
            "schedulePrecacheWork" -> handleSchedulePrecacheWork(call, result)
            "cancelPrecacheWork" -> handleCancelPrecacheWork(result)
            "precacheWorkState" -> handlePrecacheWorkState(result)
            "fullCacheStats" -> handleFullCacheStats(call, result)
            else -> result.notImplemented()
        }
    }

    // ──────────── 元数据 EXIF（P0）────────────

    private fun handleGetMetadata(call: MethodCall, result: Result) {
        val repo = repository
        if (repo == null) {
            result.error(MsError.InvalidArg("Repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrEmpty()) {
            result.error(MsError.InvalidArg("id 为空").code, null, null); return
        }
        ioExecutor.execute {
            val md = try {
                repo.getMetadata(id)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.MetadataFailed(e.message ?: "未知错误").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post { result.success(md) }
        }
    }

    // ──────────── 权限 ────────────

    private fun readPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            android.Manifest.permission.READ_MEDIA_IMAGES
        } else {
            android.Manifest.permission.READ_EXTERNAL_STORAGE
        }

    /// 读权限检测。Android 14+（API 34）用户可能选「选择照片」部分授权：
    /// READ_MEDIA_IMAGES=denied 但 READ_MEDIA_VISUAL_USER_SELECTED=granted——
    /// 此时 MediaStore 查询自动只返回所选子集，必须视为「已授权」，否则
    /// 权限页与系统选择器之间死循环。完整/部分授权均返回 true。
    private fun hasReadPermission(): Boolean {
        val act = activity ?: return false
        val ctx = act.applicationContext
        if (ContextCompat.checkSelfPermission(ctx, readPermission()) ==
            PackageManager.PERMISSION_GRANTED
        ) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            ) == PackageManager.PERMISSION_GRANTED
        }
        return false
    }

    private fun handleRequestPermission(result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        if (hasReadPermission()) {
            result.success(true); return
        }
        if (pendingPermissionResult != null) {
            result.error(MsError.InvalidArg("已有权限请求进行中").code, null, null); return
        }
        pendingPermissionResult = result
        try {
            act.requestPermissions(arrayOf(readPermission()), REQUEST_PERMISSION)
        } catch (e: Exception) {
            pendingPermissionResult = null
            result.success(false)
        }
    }

    /// 请求 ACCESS_MEDIA_LOCATION（运行时权限）。Android 10+ 未授权时系统
    /// 剥离 content URI 的 EXIF 精确位置标签 → 详情面板「位置」恒空。
    /// 复用 REQUEST_PERMISSION 的 pending 回调链。
    private fun handleRequestAccessMediaLocation(result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        if (ContextCompat.checkSelfPermission(
                act.applicationContext,
                android.Manifest.permission.ACCESS_MEDIA_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true); return
        }
        if (pendingPermissionResult != null) {
            result.success(false); return
        }
        pendingPermissionResult = result
        try {
            act.requestPermissions(
                arrayOf(android.Manifest.permission.ACCESS_MEDIA_LOCATION),
                REQUEST_PERMISSION
            )
        } catch (e: Exception) {
            pendingPermissionResult = null
            result.success(false)
        }
    }

    // ──────────── MANAGE_MEDIA 特殊权限（Android 12+，零弹窗媒体操作） ────────────

    private fun hasManageMediaPermission(): Boolean {
        val repo = repository ?: return false
        return repo.hasManageMediaPermission()
    }

    /// 跳转本应用的系统设置详情页（永久拒绝授权后的唯一出口——
    /// requestPermissions 在「不再询问」后立即回调 denied 不弹窗）。
    private fun handleOpenAppSettings(result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        try {
            val intent = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", act.packageName, null)
            ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
            act.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("无法跳转应用设置: ${e.message}").code, e.message, null)
        }
    }

    /// 跳转系统「媒体管理应用」设置页（MANAGE_MEDIA 是特殊权限，只能系统设置开启）
    private fun handleRequestManageMedia(result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true); // Android 11 及以下不需要
            return
        }
        try {
            val intent = Intent(android.provider.Settings.ACTION_REQUEST_MANAGE_MEDIA).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            act.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("无法跳转媒体管理设置: ${e.message}").code, e.message, null)
        }
    }

    /// 设备总内存（MB）。[ente 对齐] 解码防崩阈值：RAM < 5GB → 24MP 上限，
    /// 否则 100MP（ente zoomable_image _maxImagePixels，防 flutter/flutter#110331）。
    private fun handleTotalRamMb(result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        try {
            val am = act.getSystemService(android.content.Context.ACTIVITY_SERVICE)
                as android.app.ActivityManager
            val info = android.app.ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            result.success((info.totalMem / (1024L * 1024L)).toInt())
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("读取内存失败: ${e.message}").code, e.message, null)
        }
    }

    // ──────────── 方法实现 ────────────

    private fun requireRepo(): MediaStoreRepository? {
        val repo = repository
        if (repo == null) {
            return null
        }
        return repo
    }

    private fun handleListBuckets(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        if (!hasReadPermission()) {
            result.error(MsError.PermissionDenied.code, MsError.PermissionDenied.message, null); return
        }
        val sortBy = call.argument<String>("sortBy") ?: "dateCreated"
        val asc = call.argument<Boolean>("asc") ?: false
        // 全表扫描 + 内存聚合，放后台线程避免主线程卡顿（图库上万张时 100ms+）
        ioExecutor.execute {
            try {
                val buckets = repo.listBuckets(sortBy, asc)
                mainHandler.post { result.success(buckets.map { it.toMap() }) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("listBuckets 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    private fun handleScanImages(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        if (!hasReadPermission()) {
            result.error(MsError.PermissionDenied.code, MsError.PermissionDenied.message, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val bucketIds = (call.argument<List<String>>("bucketIds") ?: emptyList())
        val afterCursor = call.argument<String>("afterCursor")
        val limit = call.argument<Int>("limit") ?: 60
        val sortBy = call.argument<String>("sortBy") ?: "dateCreated"
        val asc = call.argument<Boolean>("asc") ?: false
        val favoritesOnly = call.argument<Boolean>("favoritesOnly") ?: false
        val trashedOnly = call.argument<Boolean>("trashedOnly") ?: false
        // 扫描放后台线程：大相册 cursor 遍历耗时，主线程会掉帧
        ioExecutor.execute {
            try {
                val page = repo.scanImages(bucketIds, afterCursor, limit, sortBy, asc, favoritesOnly, trashedOnly)
                mainHandler.post { result.success(page.toMap()) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("scanImages 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    // ──────────── 收藏（P1b）────────────

    private fun handleRequestFavorite(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        val favorite = call.argument<Boolean>("favorite") ?: true

        if (pendingFavoriteResult != null) {
            result.error(MsError.InvalidArg("已有收藏请求进行中").code, null, null); return
        }
        val intentSender = try {
            repo.requestFavorite(ids, favorite)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("requestFavorite 异常: ${e.message}").code, e.message, null); return
        }
        if (intentSender == null) {
            // minSdk 30 下 createFavoriteRequest 恒可用：null 只会是内部构造
            // 异常——报 error 而非 success(true)（旧误报会让 Dart 乐观更新
            // 不回滚，收藏状态与磁盘脱节）。
            result.error(MsError.QueryFailed("requestFavorite 未返回系统弹窗").code, null, null); return
        }
        pendingFavoriteResult = result
        try {
            act.startIntentSenderForResult(intentSender, REQUEST_FAVORITE, null, 0, 0, 0)
        } catch (e: Exception) {
            pendingFavoriteResult = null
            result.error(MsError.QueryFailed("启动收藏弹窗失败: ${e.message}").code, e.message, null)
        }
    }

    // ──────────── 回收站（P1a）────────────

    private fun handleRequestTrash(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        if (ids.isEmpty()) {
            result.success(true); return
        }
        if (pendingTrashResult != null) {
            result.error(MsError.InvalidArg("已有回收站请求进行中").code, null, null); return
        }
        val intentSender = try {
            repo.requestTrash(ids)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("requestTrash 异常: ${e.message}").code, e.message, null); return
        }
        if (intentSender == null) {
            // minSdk 30 下 createTrashRequest 恒可用：null 只会是内部构造异常
            result.error(MsError.QueryFailed("requestTrash 未返回系统弹窗").code, null, null); return
        }
        pendingTrashResult = result
        try {
            act.startIntentSenderForResult(intentSender, REQUEST_TRASH, null, 0, 0, 0)
        } catch (e: Exception) {
            pendingTrashResult = null
            result.error(MsError.QueryFailed("启动回收站弹窗失败: ${e.message}").code, e.message, null)
        }
    }

    private fun handleRequestRestore(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        if (ids.isEmpty()) {
            result.success(true); return
        }
        if (pendingRestoreResult != null) {
            result.error(MsError.InvalidArg("已有恢复请求进行中").code, null, null); return
        }
        val intentSender = try {
            repo.requestRestore(ids)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("requestRestore 异常: ${e.message}").code, e.message, null); return
        }
        if (intentSender == null) {
            // minSdk 30 下 createTrashRequest 恒可用：null 只会是内部构造异常
            result.error(MsError.QueryFailed("requestRestore 未返回系统弹窗").code, null, null); return
        }
        pendingRestoreResult = result
        try {
            act.startIntentSenderForResult(intentSender, REQUEST_RESTORE, null, 0, 0, 0)
        } catch (e: Exception) {
            pendingRestoreResult = null
            result.error(MsError.QueryFailed("启动恢复弹窗失败: ${e.message}").code, e.message, null)
        }
    }

    /// 批量 HDR 检测（后台补测通道，见 repo.detectHdrs）。IO 密集
    /// （每张 miss 一次 64KB 头读），必须走 ioExecutor，绝不占主线程。
    private fun handleDetectHdrs(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        if (!hasReadPermission()) {
            result.error(MsError.PermissionDenied.code, MsError.PermissionDenied.message, null); return
        }
        val ids = call.argument<List<String>>("ids") ?: emptyList()
        // Dart int 经 StandardMessageCodec 解为 Integer/Long（视大小），
        // 统一按 Number 转 Long。
        val mtimes = (call.argument<List<Number>>("mtimes") ?: emptyList()).map { it.toLong() }
        val mimes = call.argument<List<String>>("mimes") ?: emptyList()
        ioExecutor.execute {
            try {
                val flags = repo.detectHdrs(ids, mtimes, mimes)
                mainHandler.post { result.success(flags) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("detectHdrs 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    private fun handleReadMeta(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        ioExecutor.execute {
            try {
                val meta = repo.readMeta(id)
                mainHandler.post { result.success(meta.toMap()) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("readMeta 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    /// 批量 EXIF 索引（搜索页分类数据源）。入参 ids 分批传入，返回
    /// id → { dateTakenMs / lat / lng / camera }。进度累计在 Dart 侧
    /// （设置页「智能识别」区展示）。
    private fun handleIndexSearchMeta(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val ids = call.argument<List<String>>("ids")
        if (ids.isNullOrEmpty()) {
            result.error(MsError.InvalidArg("ids 缺失").code, null, null); return
        }
        ioExecutor.execute {
            try {
                val metas = repo.indexSearchMeta(ids)
                mainHandler.post { result.success(metas) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        MsError.QueryFailed("indexSearchMeta 异常: ${e.message}").code,
                        e.message, null
                    )
                }
            }
        }
    }

    /// 批量反地理编码（搜索页「地点」分类）。入参 [lat, lng] 列表，
    /// 出参同长度数组，每项 { country / adminArea / locality }。
    /// Geocoder 慢（网络请求），走 ioExecutor；跨批网格缓存见 repo。
    private fun handleGeocodePlaces(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val coords = call.argument<List<List<Double>>>("coords")
        if (coords == null) {
            result.error(MsError.InvalidArg("coords 缺失").code, null, null); return
        }
        ioExecutor.execute {
            try {
                val places = repo.geocodePlaces(coords)
                mainHandler.post { result.success(places) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        MsError.QueryFailed("geocodePlaces 异常: ${e.message}").code,
                        e.message, null
                    )
                }
            }
        }
    }

    private fun handleReadBytes(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        val max = call.argument<Int>("maxBytes") ?: 0
        // 读盘放后台线程，避免阻塞 UI（网格滚动时大量并发读取）
        ioExecutor.execute {
            try {
                val bytes = repo.readBytes(id, max)
                mainHandler.post { result.success(bytes) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("readBytes 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    private fun handleReadThumbnail(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        val width = call.argument<Int>("width") ?: 256
        val height = call.argument<Int>("height") ?: 256
        // 源图 DATE_MODIFIED（毫秒，可空）：磁盘缩略图缓存校验用
        val dateModifiedMs = call.argument<Long?>("dateModifiedMs")
        // 方形 cover 显示（网格 cell/封面）→ 长图走 centerCrop；
        // contain 显示（大图渐进链）→ fit-inside（全图 aspect）
        val squareCrop = call.argument<Boolean>("squareCrop") ?: false
        // loadThumbnail + compress 放后台线程，避免卡 UI
        ioExecutor.execute {
            try {
                val bytes = repo.readThumbnail(id, width, height, dateModifiedMs, squareCrop)
                mainHandler.post { result.success(bytes) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("readThumbnail 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    private fun handleReadSampledImage(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        val targetWidth = call.argument<Int>("targetWidth") ?: 1920
        // native 下采样解码放后台线程,避免卡 UI
        ioExecutor.execute {
            try {
                val data = repo.readSampledImage(id, targetWidth)
                mainHandler.post { result.success(data) }
            } catch (e: MsError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("readSampledImage 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    // ──────────── 空闲预缓存（channel 层） ────────────

    private fun handlePrecacheFullImage(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        val targetWidth = call.argument<Int>("targetWidth") ?: 1152
        // Number 兼容收（epoch ms 是 int64，argument<Long> 强转有 2^30 溢出
        // 前科——见 handleSetFullCacheQuota 注释）。
        val dateModifiedMs = call.argument<Number>("dateModifiedMs")?.toLong()
        ioExecutor.execute {
            val code = try {
                repo.precacheFullImage(id, targetWidth, dateModifiedMs)
            } catch (e: Exception) {
                3
            }
            mainHandler.post { result.success(code) }
        }
    }

    private fun handleSetFullCacheQuota(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        // ⚠️ MethodChannel 编码坑：Dart int 在 2^31 内以 32 位 Integer 到达，
        // argument<Long> 强转失败返回 null（1GB=2^30 正中招）——用 Number
        // 兼容收再 toLong。此 bug 曾使配额设置静默失败、Kotlin 恒用默认
        // 128MB → 预缓存 LRU 环流删最新照片。
        val bytes = (call.argument<Number>("bytes"))?.toLong()
        if (bytes == null || bytes <= 0) {
            result.error(MsError.InvalidArg("bytes 非法").code, null, null); return
        }
        ioExecutor.execute {
            try {
                repo.setFullCacheQuota(bytes)
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("setFullCacheQuota 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    private fun handleClearImageCaches(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val clearThumb = call.argument<Boolean>("clearThumb") ?: false
        ioExecutor.execute {
            val freed = try {
                repo.clearImageCaches(clearThumb)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("clearImageCaches 异常: ${e.message}").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post { result.success(freed) }
        }
    }

    private fun handleImageCacheBytes(result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        ioExecutor.execute {
            val sizes = try {
                repo.imageCacheBytes()
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("imageCacheBytes 异常: ${e.message}").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post { result.success(sizes) }
        }
    }

    // ──────────── WorkManager 全库预缓存调度 ────────────

    /// 排队全库预缓存任务（约束：仅存储不低——2026-08-29 用户定调去掉
    /// 充电限制，排队后系统给窗口即跑）。KEEP 策略幂等——已排队/运行中
    /// 不重复叠加；跑完出队，下次冷启动/开关打开时再排（已缓存段 skip
    /// 秒过，增量成本低）。
    private fun handleSchedulePrecacheWork(call: MethodCall, result: Result) {
        val ctx = appContext ?: run {
            result.error(MsError.InvalidArg("appContext 未就绪").code, null, null); return
        }
        val targetWidth = call.argument<Int>("targetWidth") ?: 1152
        ioExecutor.execute {
            try {
                val constraints = Constraints.Builder()
                    .setRequiresStorageNotLow(true)
                    .build()
                val request = OneTimeWorkRequestBuilder<PrecacheWorker>()
                    .setConstraints(constraints)
                    .setInputData(workDataOf(PrecacheWorker.KEY_TARGET_WIDTH to targetWidth))
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .build()
                WorkManager.getInstance(ctx).enqueueUniqueWork(
                    PrecacheWorker.UNIQUE_NAME,
                    ExistingWorkPolicy.KEEP,
                    request,
                )
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                Log.w(TAG, "schedulePrecacheWork 异常: ${e.message}")
                mainHandler.post {
                    result.error(
                        MsError.QueryFailed("schedulePrecacheWork 异常: ${e.message}").code,
                        e.message, null,
                    )
                }
            }
        }
    }

    /// 取消预缓存任务（关开关/手动清缓存时）。
    private fun handleCancelPrecacheWork(result: Result) {
        val ctx = appContext ?: run {
            result.error(MsError.InvalidArg("appContext 未就绪").code, null, null); return
        }
        ioExecutor.execute {
            try {
                WorkManager.getInstance(ctx).cancelUniqueWork(PrecacheWorker.UNIQUE_NAME)
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                Log.w(TAG, "cancelPrecacheWork 异常: ${e.message}")
                mainHandler.post {
                    result.error(
                        MsError.QueryFailed("cancelPrecacheWork 异常: ${e.message}").code,
                        e.message, null,
                    )
                }
            }
        }
    }

    /// 预缓存任务状态："running"（跑着）/ "enqueued"（排队等充电）/
    /// "idle"（无活动任务——跑完了或从未排队）。设置页据此解释进度
    /// 「为什么不动」。KEEP 下已完成的任务保留在历史里，只报活动态。
    private fun handlePrecacheWorkState(result: Result) {
        val ctx = appContext ?: run {
            result.error(MsError.InvalidArg("appContext 未就绪").code, null, null); return
        }
        ioExecutor.execute {
            val state = try {
                val infos = WorkManager.getInstance(ctx)
                    .getWorkInfosForUniqueWork(PrecacheWorker.UNIQUE_NAME).get()
                when {
                    infos.any { it.state == WorkInfo.State.RUNNING } -> "running"
                    infos.any { it.state == WorkInfo.State.ENQUEUED } -> "enqueued"
                    else -> "idle"
                }
            } catch (e: Exception) {
                Log.w(TAG, "precacheWorkState 查询失败: ${e.message}")
                "idle"
            }
            mainHandler.post { result.success(state) }
        }
    }

    /// 预缓存进度（cached/total 张数 + full/thumb 占用）：设置页进度行
    /// 数据源（一次 channel 往返全给齐，轮询专用）。
    private fun handleFullCacheStats(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val targetWidth = call.argument<Int>("targetWidth") ?: 1152
        ioExecutor.execute {
            val stats = try {
                repo.fullCacheStats(targetWidth)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        MsError.QueryFailed("fullCacheStats 异常: ${e.message}").code,
                        e.message, null,
                    )
                }
                return@execute
            }
            mainHandler.post { result.success(stats) }
        }
    }

    private fun handleExists(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        ioExecutor.execute {
            // 不吞错：查询失败转 error（旧 catch→false 让 Dart 把失败当
            // "文件不存在"——删除复查方向据此误删列表项）。
            val exists = try {
                repo.exists(id)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("exists 查询失败: ${e.message}").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post { result.success(exists) }
        }
    }

    private fun handleRequestDelete(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        Log.i(TAG, "handleRequestDelete: ids=$ids, pending=${pendingDeleteResult != null}")
        if (ids.isEmpty()) {
            result.success(0); return
        }
        if (pendingDeleteResult != null) {
            result.error(MsError.InvalidArg("已有删除请求进行中").code, null, null); return
        }

        // createDeleteRequest 内含 MANAGE_MEDIA 逐 URI delete 的磁盘 IO
        //（数百张可达数秒，主线程执行 ANR）——下 ioExecutor；
        // 弹窗启动、pending 置位与 result 回调回主线程。
        ioExecutor.execute {
            val dr = try {
                repo.createDeleteRequest(ids)
            } catch (e: Exception) {
                Log.e(TAG, "handleRequestDelete 异常: ${e.message}", e)
                mainHandler.post {
                    result.error(MsError.QueryFailed("requestDelete 异常: ${e.message}").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post {
                when (dr) {
                    is MediaStoreRepository.DeleteResult.Done -> {
                        // 直接完成（MANAGE_MEDIA 全量直删 / 无图可删）：
                        // 上报实际删除数——此前恒报 0，已删文件被 Dart 记为
                        // delete_failed（结果报告错误，重跑时文件已不存在）。
                        // 删除成功即清磁盘缓存文件（预缓存泄漏防线）。
                        clearImageCacheFilesAsync(ids)
                        result.success(dr.deleted)
                    }
                    is MediaStoreRepository.DeleteResult.NeedsConsent -> {
                        // 启动系统弹窗。记录直删数与弹窗 URI 数——弹窗结果
                        // 分支据此合成真实删除数（见 onActivityResult）。
                        pendingDeleteResult = result
                        pendingDeleteDirectCount = dr.alreadyDeleted
                        // 弹窗只覆盖直删失败的子集：ids.size - alreadyDeleted
                        // （旧协议记 ids.size，部分直删 + 授权的组合会虚报）。
                        pendingDeleteConsentCount = ids.size - dr.alreadyDeleted
                        // ids 记成员：弹窗成功/部分直删分支据此清缓存文件。
                        pendingDeleteIds = ids
                        try {
                            act.startIntentSenderForResult(dr.intentSender, REQUEST_DELETE, null, 0, 0, 0)
                        } catch (e: Exception) {
                            pendingDeleteResult = null
                            result.error(MsError.QueryFailed("启动删除弹窗失败: ${e.message}").code, e.message, null)
                        }
                    }
                }
            }
        }
    }

    /// 删除成功后清这些 id 的磁盘缓存文件（full + thumb 各目录 `{id}.jpg`）。
    /// 文件 IO 下 ioExecutor；失败静默（残留由 LRU trim 兜底回收）。
    private fun clearImageCacheFilesAsync(ids: List<String>) {
        val repo = repository ?: return
        ioExecutor.execute {
            for (id in ids) {
                id.toLongOrNull()?.let { repo.deleteImageCacheFiles(it) }
            }
        }
    }

    // ──────────── 查询相册 RELATIVE_PATH（模式二用） ────────────

    private fun handleGetBucketRelativePath(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val bucketId = call.argument<String>("bucketId")
        if (bucketId.isNullOrBlank()) {
            result.error(MsError.InvalidArg("bucketId 缺失").code, null, null); return
        }
        ioExecutor.execute {
            try {
                val path = repo.getBucketRelativePath(bucketId)
                mainHandler.post { result.success(path) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("getBucketRelativePath 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    // ──────────── 批量移动（改 RELATIVE_PATH） ────────────

    private fun handleRequestMove(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (ids.isEmpty() || relativePath.isEmpty()) {
            result.success(0); return
        }
        if (pendingMoveResult != null) {
            result.error(MsError.InvalidArg("已有移动请求进行中").code, null, null); return
        }

        // moveToRelativePath 内含逐 URI update 的磁盘 IO（Run 一次可上千张，
        // 主线程执行必 ANR）——下 ioExecutor；弹窗启动与 result 回调回主线程。
        ioExecutor.execute {
            val mr = try {
                repo.moveToRelativePath(ids, relativePath)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("requestMove 异常: ${e.message}").code, e.message, null)
                }
                return@execute
            }
            mainHandler.post {
                when (mr) {
                    is MediaStoreRepository.MoveResult.Done -> {
                        // 直接完成（MANAGE_MEDIA 或自有文件），返回实际成功 id 集
                        result.success(mr.movedIds)
                    }
                    is MediaStoreRepository.MoveResult.NeedsConsent -> {
                        // 需要用户授权（其他 app 的文件）——记录参数，授权通过后重新 doMove。
                        // alreadyMoved=弹窗前直移子集，取消时据此上报部分成功。
                        pendingMoveResult = result
                        pendingMoveIds = ids
                        pendingMoveRelativePath = relativePath
                        pendingMoveAlreadyMoved = mr.alreadyMoved
                        try {
                            act.startIntentSenderForResult(mr.intentSender, REQUEST_MOVE, null, 0, 0, 0)
                        } catch (e: Exception) {
                            pendingMoveResult = null
                            result.error(MsError.QueryFailed("启动移动弹窗失败: ${e.message}").code, e.message, null)
                        }
                    }
                }
            }
        }
    }

    /// 重命名单张（update DISPLAY_NAME）。先预检同目录同名 → NAME_EXISTS；
    /// 他人文件走 createWriteRequest 授权（同 move 双分支）。
    private fun handleRequestRename(call: MethodCall, result: Result) {
        val act = activity ?: run {
            result.error(MsError.InvalidArg("Activity 未绑定").code, null, null); return
        }
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id") ?: ""
        val newName = call.argument<String>("newName") ?: ""
        if (id.isEmpty() || newName.isEmpty()) {
            result.success(0); return
        }
        if (pendingRenameResult != null) {
            result.error(MsError.InvalidArg("已有重命名请求进行中").code, null, null); return
        }

        // nameExistsInDir 预检 + renameTo update 都是磁盘 IO——下 ioExecutor，
        // 弹窗启动与 result 回调回主线程。
        ioExecutor.execute {
            try {
                // 预检：同目录同名（排除自身）→ 直接报错，弹窗前拦住
                if (repo.nameExistsInDir(id, newName)) {
                    mainHandler.post {
                        result.error(MsError.NameExists.code, MsError.NameExists.message, null)
                    }
                    return@execute
                }
                val rr = repo.renameTo(id, newName)
                mainHandler.post {
                    when (rr) {
                        is MediaStoreRepository.MoveResult.Done -> result.success(rr.movedIds.size)
                        is MediaStoreRepository.MoveResult.NeedsConsent -> {
                            pendingRenameResult = result
                            pendingRenameId = id
                            pendingRenameNewName = newName
                            try {
                                act.startIntentSenderForResult(rr.intentSender, REQUEST_RENAME, null, 0, 0, 0)
                            } catch (e: Exception) {
                                pendingRenameResult = null
                                result.error(MsError.QueryFailed("启动重命名弹窗失败: ${e.message}").code, e.message, null)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("requestRename 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    /// 批量复制到目标 RELATIVE_PATH（insert 新条目 + 流拷贝，零弹窗）。
    /// 文件 IO 放 ioExecutor，不阻塞主线程（大文件拷贝可秒级）。
    private fun handleRequestCopy(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        val relativePath = call.argument<String>("relativePath") ?: ""
        if (ids.isEmpty() || relativePath.isEmpty()) {
            result.success(0); return
        }
        ioExecutor.execute {
            try {
                val success = repo.copyToRelativePath(ids, relativePath)
                mainHandler.post { result.success(success) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(MsError.QueryFailed("requestCopy 异常: ${e.message}").code, e.message, null)
                }
            }
        }
    }

    /// 重命名对话框实时校验：同目录同名查询（Dart 侧禁用 Apply 按钮）。
    private fun handleNameExists(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id") ?: ""
        val newName = call.argument<String>("newName") ?: ""
        ioExecutor.execute {
            val exists = try {
                repo.nameExistsInDir(id, newName)
            } catch (e: Exception) {
                false
            }
            mainHandler.post { result.success(exists) }
        }
    }
}

// ───────────────────────── MediaStore 变更事件流 ─────────────────────────

/// EventChannel StreamHandler：把 ContentObserver 的变更通知转发给 Dart 端。
///
/// 工作流：
///   1. Dart 订阅 events channel → onListen 保存 sink
///   2. ContentObserver.onChange 触发 → notifyChanged() 经 mainHandler 发 "changed" 事件
///   3. Dart 取消订阅 → onCancel 清空 sink
///
/// 防抖：MediaStore 单次操作（如批量删除）可能触发多次 onChange，
/// 用 300ms 防抖合并，避免 Dart 端短时间重复刷新。
class MediaChangeStreamHandler(private val resolver: android.content.ContentResolver) :
    EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingUris = mutableSetOf<android.net.Uri>()
    private var pendingRefresh = false
    private var debounceToken: Any? = null
    private val ioPool = Executors.newSingleThreadExecutor()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /// 由 ContentObserver 调用。防抖 300ms 后分类并发送结构化事件（P1c）。
    /// [uri] 为 null（非 item 级变更）或无法解析 → 全量 refresh 兜底。
    /// 分类启发式（移植自 photo_manager PhotoManagerNotifyChannel）：
    ///   查不到行 → delete；now - DATE_ADDED < 30s → insert；否则 update。
    fun notifyChanged(uri: android.net.Uri?) {
        synchronized(this) {
            if (uri != null) pendingUris.add(uri) else pendingRefresh = true
        }
        val token = Object()
        debounceToken = token
        mainHandler.postDelayed({
            if (token !== debounceToken || sink == null) return@postDelayed
            val (uris, refresh) = synchronized(this) {
                val u = pendingUris.toList()
                pendingUris.clear()
                val r = pendingRefresh
                pendingRefresh = false
                u to r
            }
            // 后台分类（查 MediaStore 行），主线程推送 sink
            ioPool.execute {
                val events = if (refresh || uris.isEmpty() || uris.size > 20) {
                    listOf(mapOf<String, Any?>("type" to "refresh"))
                } else {
                    classify(uris)
                }
                mainHandler.post {
                    if (sink != null) for (e in events) sink?.success(e)
                }
            }
        }, 300)
    }

    private fun classify(uris: List<android.net.Uri>): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val nowSec = System.currentTimeMillis() / 1000
        for (uri in uris) {
            val id = uri.lastPathSegment
            val longId = id?.toLongOrNull()
            if (id.isNullOrEmpty() || longId == null) {
                // 非数字 id（collection 级 uri）→ 全量刷新兜底
                return listOf(mapOf<String, Any?>("type" to "refresh"))
            }
            val itemUri = android.content.ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
            )
            try {
                var found = false
                resolver.query(
                    itemUri,
                    arrayOf(MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.BUCKET_ID),
                    null, null, null
                )?.use { c ->
                    if (c.moveToFirst()) {
                        found = true
                        val da = if (c.isNull(0)) 0L else c.getLong(0)
                        val bid = if (c.isNull(1)) null else c.getString(1)
                        val type = if (nowSec - da < 30) "insert" else "update"
                        result.add(mapOf<String, Any?>("type" to type, "id" to id, "bucketId" to bid))
                    }
                }
                if (!found) result.add(mapOf<String, Any?>("type" to "delete", "id" to id))
            } catch (e: Exception) {
                return listOf(mapOf<String, Any?>("type" to "refresh"))
            }
        }
        return if (result.isEmpty()) listOf(mapOf<String, Any?>("type" to "refresh")) else result
    }
}
