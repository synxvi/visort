package com.synxvi.visort.share

import android.content.ClipData
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// ───────────────────────── 分享 MethodChannel 入口 ─────────────────────────
//
// channel: "visort/share"
//
// 方法：
//   share(ids, mimes) → 系统分享面板（Intent.createChooser）
//     ids:   MediaStore _ID 列表（与 Dart MsImageInfo.id 同源）
//     mimes: 并行 MIME 列表（Dart 侧已松弛为大类型 image/*，见下）
//     返回 bool：是否成功唤起面板（无接收方应用 → false，Dart toast）
//
// 照抄 Aves AppAdapterHandler.share（MediaStore content URI 场景）：
//   · URI = ContentUris.withAppendedId(Images.Media.EXTERNAL_CONTENT_URI, id)，
//     MediaStore 的 content:// 本就可授权分享，无需 FileProvider
//     （Aves getShareableUri 对 content:// 也是直接透传，只转 file://）。
//   · 单项 ACTION_SEND + EXTRA_STREAM（部分应用只收单项）；
//     多项 ACTION_SEND_MULTIPLE + EXTRA_STREAM 列表。
//   · MIME 推导（Aves 同款）：全同 → 该类型；同大类 → 大类/*；混合 → */*。
//     Dart 侧已把 mime 松弛为大类型（Aves mimeTypeAnySubtype 同思路：
//     Google Lens 只声明接收 image/jpeg 但实际能处理更多格式，用 image/*
//     让 chooser 匹配更宽），故这里实际恒走前两档。
//   · FLAG_GRANT_READ_URI_PERMISSION 授予接收方读权限（必需，否则对方
//     打不开 content URI）。
//   · ClipData 挂在 chooser intent 上：Android 12+ 系统 UI（快捷分享/
//     预览）读 chooser 的 clip；接收方拿 URI 仍走 target 的 EXTRA_STREAM。
//
// 权限：无需额外声明（读 MediaStore 已有；URI 授权走 intent flag）。

private const val CHANNEL = "visort/share"
private const val TAG = "SharePlugin"

class SharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "share" -> handleShare(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleShare(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: run {
            result.error("SHARE_FAILED", "context 未就绪", null)
            return
        }
        val ids = call.argument<List<String>>("ids").orEmpty()
        val mimes = call.argument<List<String>>("mimes").orEmpty()
        if (ids.isEmpty() || ids.size != mimes.size) {
            result.error("INVALID_ARG", "ids/mimes 缺失或长度不一致 ids=${ids.size} mimes=${mimes.size}", null)
            return
        }

        val uriList = ArrayList<Uri>(ids.size)
        ids.forEachIndexed { i, id ->
            val n = id.toLongOrNull() ?: return@forEachIndexed
            uriList.add(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, n))
        }
        if (uriList.isEmpty()) {
            result.error("INVALID_ARG", "ids 均非数字", null)
            return
        }

        // MIME 推导（Aves 同款，见文件头注释）
        val mimeType = deriveMimeType(mimes)

        // 单项化简为 ACTION_SEND：部分应用能收单项但收不了多项（Aves 注释）。
        val intent = if (uriList.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uriList.first())
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = mimeType
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uriList)
            }
        }.apply {
            // 授予接收方读权限（EXTRA_STREAM 的 URI 授权由系统 chooser
            // 转发 target 时按本 flag 生效）
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        // createChooser 返回【全新】intent，不继承 target 的任何 flag——
        // applicationContext 启动 Activity 必须 NEW_TASK，缺它直接
        // AndroidRuntimeException（表现为「分享失败」，2026-09 真机实测）。
        val chooser = Intent.createChooser(intent, null).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // clip 挂 chooser 而非 target：Android 12+ 系统 UI（快捷分享/
            // 预览）读的是 chooser 的 clipData（share_plus 同做法）；target
            // 的 EXTRA_STREAM + flag 才是接收方拿 URI 的正路。
            clipData = ClipData.newRawUri(null, uriList.first()).apply {
                uriList.drop(1).forEach { addItem(ClipData.Item(it)) }
            }
        }

        try {
            // 无任何应用能接收 → false（Dart 侧 toast 提示）
            if (intent.resolveActivity(ctx.packageManager) == null) {
                result.success(false)
                return
            }
            ctx.startActivity(chooser)
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "share failed: $e")
            result.error("SHARE_FAILED", e.message ?: e.toString(), null)
        }
    }

    /// 全同 → 该类型；同大类 → 大类/*；混合 → */*（Aves 同款推导）。
    private fun deriveMimeType(mimes: List<String>): String {
        if (mimes.distinct().size == 1) return mimes.first()
        val types = mimes.map { it.substringBefore('/') }.distinct()
        return if (types.size == 1) "$types/*" else "*/*"
    }
}
