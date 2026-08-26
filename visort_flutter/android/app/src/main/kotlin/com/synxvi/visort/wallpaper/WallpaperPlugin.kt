package com.synxvi.visort.wallpaper

import android.app.WallpaperManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// ───────────────────────── 壁纸 MethodChannel 入口 ─────────────────────────
//
// channel: "visort/wallpaper"
//
// 方法：
//   setWallpaper(bytes, which) → WallpaperManager.setStream（flags 组合）
//     bytes: Dart 裁剪页渲染好的 PNG（可见区域 + 滚动扩展已在 Dart 完成）
//     which: 1=主屏(FLAG_SYSTEM)  2=锁屏(FLAG_LOCK)  3=两者
//
// 照抄 Aves WallpaperHandler.kt：原生侧零像素工作（不读 MediaStore、不
// 解码、不裁剪）——预览与结果一致性的关键：Dart 用它渲染预览的【同一张
// 解码图】做 Canvas 裁剪（wallpaper_crop_page.dart），所见即所得，不存在
// 二次解码的坐标系/EXIF 对齐问题。
//
// 与系统相册考古（SetAsWallpaperActivity）对齐点：flags 组合一次 setStream、
// JPEG/PNG quality 由 Dart 侧编码决定。ColorOS 特权部分不搬（锁屏时钟
// 文字色/关画报/三方锁屏检测，见 memory wallpaper-setaswallpaper-arch）。
//
// 权限：SET_WALLPAPER（普通权限，manifest 声明即生效）。

private const val CHANNEL = "visort/wallpaper"
private const val TAG = "WallpaperPlugin"

class WallpaperPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    /// 壁纸设置是低频操作，单线程足够；解码/压缩耗时必须离开主线程。
    private val ioExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

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
            "setWallpaper" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val which = call.argument<Int>("which") ?: 0
                val ctx = appContext
                if (bytes == null || bytes.isEmpty() || which !in 1..3 || ctx == null) {
                    result.error("INVALID_ARG", "bytes/which 缺失或非法", null)
                    return
                }
                ioExecutor.execute {
                    try {
                        setWallpaperInternal(ctx, bytes, which)
                        mainHandler.post { result.success(true) }
                    } catch (e: Throwable) {
                        android.util.Log.w(TAG, "setWallpaper failed: $e")
                        mainHandler.post {
                            result.error("WALLPAPER_FAILED", e.message ?: e.toString(), null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun setWallpaperInternal(ctx: Context, bytes: ByteArray, which: Int) {
        val wm = WallpaperManager.getInstance(ctx)
        if (!wm.isWallpaperSupported || !wm.isSetWallpaperAllowed) {
            throw IllegalStateException("系统不允许设置壁纸")
        }
        val flags = (if (which == 1 || which == 3) WallpaperManager.FLAG_SYSTEM else 0) or
            (if (which == 2 || which == 3) WallpaperManager.FLAG_LOCK else 0)
        bytes.inputStream().use { input ->
            // 第三参 allowBackup=false（对齐系统相册考古结论）：true 会让
            // 部分 ROM 把壁纸回写进备份/云恢复链路。
            wm.setStream(input, null, false, flags)
        }
    }
}
