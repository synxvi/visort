package com.sortr.sortr_flutter.mediastore

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
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
//
// 方法：
//   listBuckets()               → 列出所有相册（id/name/count）
//   scanImages(bucketIds, max)  → 按相册扫描图片
//   readMeta(id)                → 单图元信息
//   readBytes(id, maxBytes)     → 读字节
//   exists(id)                  → 存在性
//   requestDelete(ids)          → 批量删除（系统弹窗确认）
//   hasPermission()             → 检查 READ_MEDIA_IMAGES
//   requestPermission()         → 请求 READ_MEDIA_IMAGES
//
// 关键机制：
//   1. ActivityAware 管理生命周期
//   2. ActivityResultListener 处理 createDeleteRequest 的系统弹窗回调
//   3. RequestPermissionsResultListener 处理权限请求回调

private const val CHANNEL = "sortr/mediastore"
private const val TAG = "MsPlugin"

private const val REQUEST_DELETE = 0x4D53 // "MS"
private const val REQUEST_MOVE = 0x4D56 // "MV"
private const val REQUEST_PERMISSION = 0x5045 // "PE"

class MediaStorePlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var repository: MediaStoreRepository? = null

    /// IO 线程池：图片字节/缩略图读盘放后台，避免阻塞 UI 线程导致滚动卡顿
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

    // ──────────── FlutterPlugin 生命周期 ────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        Log.i(TAG, "MediaStorePlugin 已附加（channel=$CHANNEL）")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
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
            "readBytes" -> handleReadBytes(call, result)
            "readThumbnail" -> handleReadThumbnail(call, result)
            "exists" -> handleExists(call, result)
            "requestDelete" -> handleRequestDelete(call, result)
            "getBucketRelativePath" -> handleGetBucketRelativePath(call, result)
            "requestMove" -> handleRequestMove(call, result)
            "hasPermission" -> result.success(hasReadPermission())
            "requestPermission" -> handleRequestPermission(result)
            "hasManageMedia" -> result.success(hasManageMediaPermission())
            "requestManageMedia" -> handleRequestManageMedia(result)
            else -> result.notImplemented()
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
        val sortBy = call.argument<String>("sortBy") ?: "dateTaken"
        val asc = call.argument<Boolean>("asc") ?: false
        try {
            result.success(repo.listBuckets(sortBy, asc).map { it.toMap() })
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("listBuckets 异常: ${e.message}").code, e.message, null)
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
        val max = call.argument<Int>("max") ?: 2000
        val offset = call.argument<Int>("offset") ?: 0
        val sortBy = call.argument<String>("sortBy") ?: "dateTaken"
        val asc = call.argument<Boolean>("asc") ?: false
        try {
            result.success(repo.scanImages(bucketIds, max, offset, sortBy, asc).map { it.toMap() })
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("scanImages 异常: ${e.message}").code, e.message, null)
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
        try {
            result.success(repo.readMeta(id).toMap())
        } catch (e: MsError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("readMeta 异常: ${e.message}").code, e.message, null)
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
        try {
            result.success(repo.exists(id))
        } catch (e: Exception) {
            result.success(false)
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
        try {
            val path = repo.getBucketRelativePath(bucketId)
            result.success(path)
        } catch (e: Exception) {
            result.error(MsError.QueryFailed("getBucketRelativePath 异常: ${e.message}").code, e.message, null)
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
