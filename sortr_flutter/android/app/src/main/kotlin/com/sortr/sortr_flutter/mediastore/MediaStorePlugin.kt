package com.sortr.sortr_flutter.mediastore

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
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

// ───────────────────────── MediaStore MethodChannel 入口 ─────────────────────────
//
// 对接 Dart 侧 AndroidMediaStoreFileSystem。
// channel: "sortr/mediastore"
// events channel: "sortr/mediastore-events"（ContentObserver 变更通知）
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

private const val CHANNEL = "sortr/mediastore"
private const val EVENTS_CHANNEL = "sortr/mediastore-events"
private const val TAG = "MsPlugin"

private const val REQUEST_DELETE = 0x4D53 // "MS"
private const val REQUEST_MOVE = 0x4D56 // "MV"
private const val REQUEST_PERMISSION = 0x5045 // "PE"
private const val REQUEST_FAVORITE = 0x4641 // "FA"
private const val REQUEST_TRASH = 0x5452 // "TR"
private const val REQUEST_RESTORE = 0x5253 // "RS"

class MediaStorePlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var mediaObserver: ContentObserver? = null
    private var binding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var repository: MediaStoreRepository? = null

    /// IO 线程池：图片字节/缩略图/查询放后台，避免阻塞 UI 线程导致滚动卡顿
    private val ioExecutor = Executors.newFixedThreadPool(4)
    /// 回主线程回调 MethodChannel.Result（result 必须在主线程调用）
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 待处理的删除请求（弹窗是异步的）
    private var pendingDeleteResult: Result? = null
    private var pendingDeleteCount: Int = 0

    /// 待处理的移动请求（弹窗是异步的）
    private var pendingMoveResult: Result? = null
    private var pendingMoveIds: List<String> = emptyList()
    private var pendingMoveRelativePath: String = ""

    /// 待处理的权限请求
    private var pendingPermissionResult: Result? = null

    /// 待处理的收藏请求（弹窗异步，P1b）
    private var pendingFavoriteResult: Result? = null

    /// 待处理的回收站/恢复请求（弹窗异步，P1a）
    private var pendingTrashResult: Result? = null
    private var pendingRestoreResult: Result? = null

    // ──────────── FlutterPlugin 生命周期 ────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
        pendingDeleteResult = null
        pendingPermissionResult = null
    }

    // ──────────── ActivityResult 回调（删除弹窗） ────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQUEST_DELETE -> {
                Log.i(TAG, "onActivityResult REQUEST_DELETE: resultCode=$resultCode (OK=${Activity.RESULT_OK}), pending=${pendingDeleteResult != null}")
                val pending = pendingDeleteResult ?: return true
                pendingDeleteResult = null
                if (resultCode == Activity.RESULT_OK) {
                    pending.success(pendingDeleteCount)
                } else {
                    pending.error(MsError.DeleteCancelled.code, MsError.DeleteCancelled.message, null)
                }
                return true
            }
            REQUEST_MOVE -> {
                val pending = pendingMoveResult ?: return true
                val ids = pendingMoveIds
                val relPath = pendingMoveRelativePath
                pendingMoveResult = null
                pendingMoveIds = emptyList()
                pendingMoveRelativePath = ""

                if (resultCode == Activity.RESULT_OK) {
                    // 授权通过，执行真正的 update（之前 update 因权限失败只返回了 intentSender）
                    val repo = repository
                    val successCount = if (repo != null) {
                        repo.doMoveToRelativePath(ids, relPath)
                    } else 0
                    pending.success(successCount)
                } else {
                    pending.success(0) // 用户取消
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
            "readMeta" -> handleReadMeta(call, result)
            "getMetadata" -> handleGetMetadata(call, result)
            "readBytes" -> handleReadBytes(call, result)
            "readThumbnail" -> handleReadThumbnail(call, result)
            "exists" -> handleExists(call, result)
            "requestDelete" -> handleRequestDelete(call, result)
            "getBucketRelativePath" -> handleGetBucketRelativePath(call, result)
            "requestMove" -> handleRequestMove(call, result)
            "requestFavorite" -> handleRequestFavorite(call, result)
            "requestTrash" -> handleRequestTrash(call, result)
            "requestRestore" -> handleRequestRestore(call, result)
            "hasPermission" -> result.success(hasReadPermission())
            "requestPermission" -> handleRequestPermission(result)
            "hasManageMedia" -> result.success(hasManageMediaPermission())
            "requestManageMedia" -> handleRequestManageMedia(result)
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

    private fun hasReadPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity!!, readPermission()) == PackageManager.PERMISSION_GRANTED

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                act.requestPermissions(arrayOf(readPermission()), REQUEST_PERMISSION)
            } else {
                result.success(true) // 老版本 manifest 声明即授予
            }
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error(MsError.FavoriteUnsupported.code, MsError.FavoriteUnsupported.message, null); return
        }
        @Suppress("UNCHECKED_CAST")
        val ids = (call.argument<List<String>>("ids") ?: emptyList())
        val favorite = call.argument<Boolean>("favorite") ?: true
        if (ids.isEmpty()) {
            result.success(true); return
        }
        if (pendingFavoriteResult != null) {
            result.error(MsError.InvalidArg("已有收藏请求进行中").code, null, null); return
        }
        val intentSender = try {
            repo.requestFavorite(ids, favorite)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("requestFavorite 异常: ${e.message}").code, e.message, null); return
        }
        if (intentSender == null) {
            result.success(true); return
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error(MsError.TrashUnsupported.code, MsError.TrashUnsupported.message, null); return
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
            result.error(MsError.TrashUnsupported.code, MsError.TrashUnsupported.message, null); return
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error(MsError.TrashUnsupported.code, MsError.TrashUnsupported.message, null); return
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
            result.error(MsError.TrashUnsupported.code, MsError.TrashUnsupported.message, null); return
        }
        pendingRestoreResult = result
        try {
            act.startIntentSenderForResult(intentSender, REQUEST_RESTORE, null, 0, 0, 0)
        } catch (e: Exception) {
            pendingRestoreResult = null
            result.error(MsError.QueryFailed("启动恢复弹窗失败: ${e.message}").code, e.message, null)
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
        // loadThumbnail + compress 放后台线程，避免卡 UI
        ioExecutor.execute {
            try {
                val bytes = repo.readThumbnail(id, width, height)
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

    private fun handleExists(call: MethodCall, result: Result) {
        val repo = requireRepo() ?: run {
            result.error(MsError.InvalidArg("repository 未就绪").code, null, null); return
        }
        val id = call.argument<String>("id")
        if (id.isNullOrBlank()) {
            result.error(MsError.InvalidArg("id 缺失").code, null, null); return
        }
        ioExecutor.execute {
            val exists = try {
                repo.exists(id)
            } catch (e: Exception) {
                false
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

        try {
            val intentSender: IntentSender? = repo.createDeleteRequest(ids)
            Log.i(TAG, "handleRequestDelete: intentSender=${if (intentSender != null) "非null(走系统弹窗)" else "null(直接删/无图)"}")
            if (intentSender == null) {
                // 老版本直接删除已完成，或无图可删
                result.success(if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) ids.size else 0)
                return
            }
            // 启动系统弹窗
            pendingDeleteResult = result
            pendingDeleteCount = ids.size
            act.startIntentSenderForResult(intentSender, REQUEST_DELETE, null, 0, 0, 0)
        } catch (e: Exception) {
            Log.e(TAG, "handleRequestDelete 异常: ${e.message}", e)
            result.error(MsError.QueryFailed("requestDelete 异常: ${e.message}").code, e.message, null)
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

        try {
            when (val mr = repo.moveToRelativePath(ids, relativePath)) {
                is MediaStoreRepository.MoveResult.Done -> {
                    // 直接完成（MANAGE_MEDIA 或自有文件），返回实际成功数
                    result.success(mr.successCount)
                }
                is MediaStoreRepository.MoveResult.NeedsConsent -> {
                    // 需要用户授权（其他 app 的文件）——记录参数，授权通过后重新 doMove
                    pendingMoveResult = result
                    pendingMoveIds = ids
                    pendingMoveRelativePath = relativePath
                    act.startIntentSenderForResult(mr.intentSender, REQUEST_MOVE, null, 0, 0, 0)
                }
            }
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("requestMove 异常: ${e.message}").code, e.message, null)
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
