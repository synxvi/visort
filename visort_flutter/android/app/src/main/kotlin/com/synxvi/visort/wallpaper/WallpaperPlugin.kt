package com.synxvi.visort.wallpaper

import android.app.WallpaperManager
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// ───────────────────────── 壁纸 MethodChannel 入口 ─────────────────────────
//
// 对标 ColorOS 系统相册 SetAsWallpaperActivity（_reverse/gallery3d 反编译考古）。
// channel: "visort/wallpaper"
//
// 方法：
//   setWallpaper(id, which)  → 解码 MediaStore 图片 → CenterCrop 到屏尺寸 →
//                              JPEG → WallpaperManager.setStream
//     which: 1=主屏(FLAG_SYSTEM)  2=锁屏(FLAG_LOCK)  3=两者
//
// 与系统相册对齐的细节：
//   - setStream(stream, null, false, which)：allowBackup=false、无 cropHint，
//     「两者」先设主屏再设锁屏（P0 方法 i==2 分支同序）。
//   - JPEG quality 100（系统相册同款）。
//   - 裁剪为居中 CenterCrop（ScalableView 初始态同款），目标恒为竖屏比例
//     （B0=max(w,h)、C0=min(w,h)）。
//
// 系统相册里的 ColorOS 特权部分【不搬】（第三方无权限）：
//   - T0()：Settings.System 写 KeyguardWallpaperTxtColor（锁屏时钟文字
//     深浅自适应）与关闭「炫彩画报」——需 WRITE_SETTINGS。
//     ⚠️ ColorOS 上若锁屏画报开启，锁屏壁纸可能被画报盖住，需用户手动
//     关一次画报（设置→壁纸与个性化）。
//   - Z0()：第三方锁屏接管检测（picture_lockscreen_apply_unsupported）。
//   - ImageProcess 亮度分析（决定锁屏文字颜色）。
//
// 解码走 BitmapRegionDecoder 只解裁剪区域 + inSampleSize 下采样，
// 内存 O(屏尺寸)，不受原图大小影响（系统相册全量解码，我们更省）。
//
// 权限：SET_WALLPAPER（普通权限，manifest 声明即生效，无运行时申请）。

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
                val id = call.argument<String>("id")
                val which = call.argument<Int>("which") ?: 0
                val ctx = appContext
                if (id == null || which !in 1..3 || ctx == null) {
                    result.error("INVALID_ARG", "id/which 缺失或非法", null)
                    return
                }
                ioExecutor.execute {
                    try {
                        setWallpaperInternal(ctx, id, which)
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

    /// id 为 MediaStore _ID（与 mediastore 插件同源），which 语义见文件头。
    private fun setWallpaperInternal(ctx: Context, id: String, which: Int) {
        val longId = id.toLongOrNull()
            ?: throw IllegalArgumentException("图片 id 非法: $id")
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        val resolver = ctx.contentResolver
        val decoder = resolver.openInputStream(uri)?.use { input ->
            BitmapRegionDecoder.newInstance(input, false)
        } ?: throw IllegalStateException("无法解码图片（损坏或格式不支持）")
        try {
            val imgW = decoder.width
            val imgH = decoder.height
            if (imgW <= 0 || imgH <= 0) throw IllegalStateException("图片尺寸非法")

            val scrW: Int
            val scrH: Int
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val b = (ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
                    ?.maximumWindowMetrics?.bounds
                    ?: ctx.resources.displayMetrics.let { android.graphics.Rect(0, 0, it.widthPixels, it.heightPixels) }
                scrW = minOf(b.width(), b.height())
                scrH = maxOf(b.width(), b.height())
            } else {
                @Suppress("DEPRECATION")
                val dm = ctx.resources.displayMetrics
                scrW = minOf(dm.widthPixels, dm.heightPixels)
                scrH = maxOf(dm.widthPixels, dm.heightPixels)
            }

            // 居中 CenterCrop：目标比例恒竖屏（系统相册 ScalableView 初始态）。
            val targetRatio = scrW.toFloat() / scrH.toFloat()
            val imgRatio = imgW.toFloat() / imgH.toFloat()
            val crop = if (imgRatio > targetRatio) {
                // 横图：高取满，宽按屏比收缩，居中
                val w = (imgH * targetRatio).toInt().coerceAtLeast(1)
                Rect((imgW - w) / 2, 0, (imgW - w) / 2 + w, imgH)
            } else {
                // 竖图：宽取满，高按屏比收缩，居中
                val h = (imgW / targetRatio).toInt().coerceAtLeast(1)
                Rect(0, (imgH - h) / 2, imgW, (imgH - h) / 2 + h)
            }

            // 下采样：crop 仍略大于目标即可（最后 createScaledBitmap 精缩），
            // 内存 O(屏尺寸)。
            var sample = 1
            while (
                crop.width() / (sample * 2) >= scrW &&
                crop.height() / (sample * 2) >= scrH
            ) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val region = decoder.decodeRegion(crop, opts)
                ?: throw IllegalStateException("裁剪解码失败")
            val scaled = if (region.width == scrW && region.height == scrH) {
                region
            } else {
                Bitmap.createScaledBitmap(region, scrW, scrH, true)
            }

            val bytes = java.io.ByteArrayOutputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 100, out)
                out.toByteArray()
            }
            // 同一对象只 recycle 一次（尺寸恰好相等时 createScaledBitmap 原样返回）。
            region.recycle()
            if (scaled !== region) scaled.recycle()

            val wm = WallpaperManager.getInstance(ctx)
            val streamFactory = { java.io.ByteArrayInputStream(bytes) }
            if (which == 1 || which == 3) {
                wm.setStream(streamFactory(), null, false, WallpaperManager.FLAG_SYSTEM)
            }
            if (which == 2 || which == 3) {
                // 「两者」各用独立流（ByteArrayInputStream 不可重读）。
                wm.setStream(streamFactory(), null, false, WallpaperManager.FLAG_LOCK)
            }
        } finally {
            decoder.recycle()
        }
    }
}
