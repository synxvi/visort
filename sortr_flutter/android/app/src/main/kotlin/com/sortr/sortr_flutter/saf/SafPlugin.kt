package com.sortr.sortr_flutter.saf

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

// ───────────────────────── SAF MethodChannel 入口 ─────────────────────────
//
// 对接 Dart 侧 AndroidSafFileSystem。
// channel: "sortr/saf"
//
// 里程碑 A0 方法：
//   pickDirectory()            → 启动 ACTION_OPEN_DOCUMENT_TREE，返回 tree URI 字符串
//   scanImages(treeUri, max)   → 递归扫描图片，返回 List<Map>
//   persistedUriPermissions()  → 列出当前持久化授权，用于验证重启后保留
//
// 设计要点：
//   1. 使用 ActivityPluginBinding.addActivityResultListener（Flutter 官方推荐方式）
//      而非 registerForActivityResult —— 后者要求在 Activity onCreate 阶段注册，
//      而 Flutter plugin 的 onAttachedToActivity 发生在 STARTED 之后，注册会静默失败。
//   2. picker 是异步的，pendingResult 必须跨 startActivityForResult→onResult 存活；
//      同一时刻只允许一个待处理请求。
//   3. takePersistableUriPermission 在拿到 tree URI 后立即调，避免遗漏。

private const val CHANNEL = "sortr/saf"
private const val TAG = "SafPlugin"

/// ACTION_OPEN_DOCUMENT_TREE 的请求码
private const val REQUEST_OPEN_TREE = 0x7301 // "SA"

class SafPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var repository: SafRepository? = null
    private var activity: Activity? = null

    /// 当前待处理的 pickDirectory 请求
    private var pendingPickResult: Result? = null

    // ──────────── FlutterPlugin 生命周期 ────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        Log.i(TAG, "SafPlugin 已附加到 engine（channel=$CHANNEL）")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ──────────── ActivityAware 生命周期 ────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        this.activity = binding.activity
        repository = SafRepository(activity!!.applicationContext)
        // 注册 Activity Result 监听（Flutter 官方推荐方式）
        binding.addActivityResultListener(this)
        Log.i(TAG, "SafPlugin 已绑定 Activity，ActivityResultListener 已注册")
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
        binding = null
        activity = null
        repository = null
        pendingPickResult?.error(SafError.Cancelled.code, "Activity 销毁", null)
        pendingPickResult = null
    }

    // ──────────── ActivityResultListener 回调 ────────────

    /// 接收 ACTION_OPEN_DOCUMENT_TREE 的结果
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN_TREE) return false

        val pending = pendingPickResult ?: return true
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.error(SafError.Cancelled.code, SafError.Cancelled.message, null)
            return true
        }

        val uri = data.data
        if (uri == null) {
            pending.error(SafError.NoUri.code, SafError.NoUri.message, null)
            return true
        }

        try {
            // 关键：拿持久化权限，否则重启失效
            repository?.takePersistablePermission(uri)
        } catch (e: SecurityException) {
            Log.w(TAG, "takePersistableUriPermission 失败: ${e.message}")
            // 不阻断——某些 provider 可能不支持持久化，仍返回 URI 让上层决定
        }

        pending.success(uri.toString())
        return true
    }

    // ──────────── MethodCall 分发 ────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // A0
            "pickDirectory" -> handlePickDirectory(result)
            "scanImages" -> handleScanImages(call, result)
            "persistedUriPermissions" -> handlePersistedPermissions(result)
            // A1
            "listSubdirs" -> handleListSubdirs(call, result)
            "readMeta" -> handleReadMeta(call, result)
            "move" -> handleMove(call, result)
            "delete" -> handleDelete(call, result)
            "exists" -> handleExists(call, result)
            "readBytes" -> handleReadBytes(call, result)
            else -> result.notImplemented()
        }
    }

    // ──────────── 方法实现 ────────────

    /// pickDirectory：启动系统目录选择器，返回 tree URI 字符串
    private fun handlePickDirectory(result: Result) {
        val act = activity ?: run {
            result.error(SafError.InvalidArg("Activity 未绑定").code, "Activity 未就绪", null)
            return
        }
        if (pendingPickResult != null) {
            result.error(
                SafError.InvalidArg("已有进行中的 pick 请求").code,
                "重复请求",
                null,
            )
            return
        }
        pendingPickResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            }
            act.startActivityForResult(intent, REQUEST_OPEN_TREE)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error(SafError.QueryFailed("startActivityForResult 失败: ${e.message}").code, e.message, null)
        }
    }

    /// scanImages：扫描指定 tree URI 下的图片
    private fun handleScanImages(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUriStr = call.argument<String>("treeUri")
        if (treeUriStr.isNullOrBlank()) {
            result.error(SafError.InvalidArg("treeUri 缺失").code, "treeUri 参数必填", null)
            return
        }
        val max = call.argument<Int>("max") ?: 500

        val treeUri = try {
            Uri.parse(treeUriStr)
        } catch (e: Exception) {
            result.error(SafError.InvalidArg("treeUri 解析失败: ${e.message}").code, e.message, null)
            return
        }

        try {
            val images = repo.scanImages(treeUri, max)
            result.success(images.map { it.toMap() })
        } catch (e: SafError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("scanImages 异常: ${e.message}").code, e.message, null)
        }
    }

    /// persistedUriPermissions：列出当前持久化授权（重启后验证用）
    private fun handlePersistedPermissions(result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val perms = repo.persistedUriPermissions()
        result.success(perms.map { it.toMap() })
    }

    // ──────────── A1 方法实现 ────────────

    /// listSubdirs：列出 tree URI 下的直接子目录
    private fun handleListSubdirs(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUri = parseTreeUri(call, result) ?: return
        try {
            val names = repo.listSubdirs(treeUri)
            result.success(names)
        } catch (e: SafError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("listSubdirs 异常: ${e.message}").code, e.message, null)
        }
    }

    /// readMeta：读取单张图片元信息
    private fun handleReadMeta(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUri = parseTreeUri(call, result) ?: return
        val docId = call.argument<String>("docId")
        if (docId.isNullOrBlank()) {
            result.error(SafError.InvalidArg("docId 缺失").code, "docId 参数必填", null)
            return
        }
        try {
            val meta = repo.readMeta(treeUri, docId)
            result.success(meta.toMap())
        } catch (e: SafError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("readMeta 异常: ${e.message}").code, e.message, null)
        }
    }

    /// move：移动文件（自动分叉同 tree / 跨 tree）
    private fun handleMove(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val srcTreeUri = parseTreeUri(call, result, key = "srcTreeUri") ?: return
        val srcDocId = call.argument<String>("srcDocId")
        val destTreeUriStr = call.argument<String>("destTreeUri")
        val destDirDocId = call.argument<String>("destDirDocId")
        val suggestedName = call.argument<String>("suggestedName")
        if (srcDocId.isNullOrBlank() || destTreeUriStr.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error(SafError.InvalidArg("参数缺失").code, "srcDocId/destTreeUri/suggestedName 必填", null)
            return
        }
        val destTreeUri = try { Uri.parse(destTreeUriStr) }
        catch (e: Exception) {
            result.error(SafError.InvalidArg("destTreeUri 解析失败").code, e.message, null); return
        }
        try {
            val moveResult = repo.move(
                srcTreeUri, srcDocId,
                destTreeUri, destDirDocId ?: "",
                suggestedName,
            )
            result.success(moveResult.toMap())
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("move 异常: ${e.message}").code, e.message, null)
        }
    }

    /// delete：删除文件
    private fun handleDelete(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUri = parseTreeUri(call, result) ?: return
        val docId = call.argument<String>("docId")
        if (docId.isNullOrBlank()) {
            result.error(SafError.InvalidArg("docId 缺失").code, "docId 参数必填", null)
            return
        }
        try {
            val ok = repo.deleteDocument(treeUri, docId)
            result.success(ok)
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("delete 异常: ${e.message}").code, e.message, null)
        }
    }

    /// exists：检查文件是否存在
    private fun handleExists(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUri = parseTreeUri(call, result) ?: return
        val docId = call.argument<String>("docId")
        if (docId.isNullOrBlank()) {
            result.error(SafError.InvalidArg("docId 缺失").code, "docId 参数必填", null)
            return
        }
        try {
            result.success(repo.exists(treeUri, docId))
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("exists 异常: ${e.message}").code, e.message, null)
        }
    }

    /// readBytes：读取文件字节（用于图片加载，支持 maxBytes 限制）
    private fun handleReadBytes(call: MethodCall, result: Result) {
        val repo = repository ?: run {
            result.error(SafError.InvalidArg("repository 未就绪").code, "Activity 未绑定", null)
            return
        }
        val treeUri = parseTreeUri(call, result) ?: return
        val docId = call.argument<String>("docId")
        if (docId.isNullOrBlank()) {
            result.error(SafError.InvalidArg("docId 缺失").code, "docId 参数必填", null)
            return
        }
        val maxBytes = call.argument<Int>("maxBytes") ?: 0
        try {
            val bytes = repo.readBytes(treeUri, docId, maxBytes)
            result.success(bytes)
        } catch (e: SafError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(SafError.QueryFailed("readBytes 异常: ${e.message}").code, e.message, null)
        }
    }

    // ──────────── 辅助：从 MethodCall 解析 treeUri ────────────

    private fun parseTreeUri(call: MethodCall, result: Result, key: String = "treeUri"): Uri? {
        val treeUriStr = call.argument<String>(key)
        if (treeUriStr.isNullOrBlank()) {
            result.error(SafError.InvalidArg("$key 缺失").code, "$key 参数必填", null)
            return null
        }
        return try {
            Uri.parse(treeUriStr)
        } catch (e: Exception) {
            result.error(SafError.InvalidArg("$key 解析失败: ${e.message}").code, e.message, null)
            null
        }
    }
}
