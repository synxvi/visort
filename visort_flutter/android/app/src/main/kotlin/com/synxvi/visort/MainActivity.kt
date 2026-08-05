package com.synxvi.visort

import android.os.Build
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.WindowManager
import android.window.BackEvent
import android.window.OnBackAnimationCallback
import android.window.OnBackInvokedDispatcher
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.synxvi.visort.mediastore.MediaStorePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注册 MediaStore MethodChannel + EventChannel plugin（visort/mediastore）
        flutterEngine.plugins.add(MediaStorePlugin())
        // SAF plugin 已移除（MediaStore 取代）。非媒体文件场景如需恢复，需重新引入 saf 包。
        // 「回桌面」通道：首页（根路由）右滑返回时 Dart 调 moveTaskToBack，
        // 等效 Home 键（task 保留后台，不 finish——finish 会从最近任务移除应用）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "visort/app")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveTaskToBack") {
                    runOnUiThread { moveTaskToBack(true) }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        applyHighRefreshRate()
        applyFixedFrameRate()
        registerBackGestureInterceptor()
    }

    private fun applyFixedFrameRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        // ⚠️ onAttachedToWindow 时机太早：Flutter embedding 的 FlutterSurfaceView 此时
        // 尚未创建（延迟 attach），findSurfaceView 返回 null → 永不注册 callback →
        // 修复：post 到 decorView 队列末尾，此时 view 树已完整。
        window.decorView.post {
            val surfaceView = findSurfaceView(window.decorView)
            android.util.Log.d("VisortFPS", "applyFixedFrameRate surfaceView=${surfaceView != null}")
            if (surfaceView == null) return@post
            val holder = surfaceView.holder
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    android.util.Log.d("VisortFPS", "surfaceCreated")
                    declareFrameRate(surfaceView)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    declareFrameRate(surfaceView)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            })
            // post 执行时 surface 可能已创建（错过 surfaceCreated 回调）——立即声明一次。
            if (holder.surface.isValid) {
                android.util.Log.d("VisortFPS", "surface already valid, declare now")
                declareFrameRate(surfaceView)
            }
        }
    }

    private fun declareFrameRate(surfaceView: SurfaceView) {
        val holder = surfaceView.holder
        val rate = pickHighestRefreshRate() ?: return
        try {
            holder.surface.setFrameRate(
                rate,
                Surface.FRAME_RATE_COMPATIBILITY_AT_LEAST,
                Surface.CHANGE_FRAME_RATE_ALWAYS,
            )
            android.util.Log.d("VisortFPS", "declareFrameRate ok rate=$rate")
        } catch (e: Throwable) {
            android.util.Log.w("VisortFPS", "setFrameRate failed: $e")
        }
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val surfaceControl = surfaceView.getSurfaceControl()
                if (surfaceControl != null) {
                    val t = android.view.SurfaceControl.Transaction()
                    t.setFrameRate(
                        surfaceControl,
                        rate,
                        Surface.FRAME_RATE_COMPATIBILITY_AT_LEAST,
                        Surface.CHANGE_FRAME_RATE_ALWAYS,
                    )
                    t.apply()
                    android.util.Log.d("VisortFPS", "surfaceControl.setFrameRate ok")
                }
            }
        } catch (e: Throwable) {
            android.util.Log.w("VisortFPS", "surfaceControl.setFrameRate failed: $e")
        }
    }

    @Suppress("DEPRECATION")
    private fun pickHighestRefreshRate(): Float? {
        val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            this.display
        } else {
            windowManager.defaultDisplay
        }
        return display?.supportedModes?.maxByOrNull { it.refreshRate }?.refreshRate
    }

    /** 递归查找渲染用的 SurfaceView（Flutter 内部是 FlutterSurfaceView）。 */
    private fun findSurfaceView(v: android.view.View): SurfaceView? {
        if (v is SurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                findSurfaceView(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    // 接管系统返回手势：window 级 OnBackAnimationCallback（API 34+）。
    //
    // 背景：ColorOS/Android 16 对“隐藏了系统栏”的应用（沉浸模式）会消费第一次返回手势
    // 用于显示系统栏，并提示“再次滑动返回”——这是系统行为，Flutter 侧无法关闭。
    // 系统相册（ColorOS）正是通过此类 window 级回调完全接管手势来做到“沉浸 + 一次滑动返回”。
    //
    // ⚠️ ColorOS 专属坑（2026-08 实测）：即使注册了本回调，若系统设置里“手势防误触”
    // 选了“全屏场景”，沉浸模式 app 仍会被识别为全屏场景，第一次滑动被防误触机制在
    // InputDispatcher 层消费（弹系统栏 + 提示“再次滑动返回”），应用代码无法绕过。
    // 系统相册不受影响（不在检测范围）。遇到该现象只能引导用户把防误触改为
    // “仅游戏场景”或“关闭”。logcat 线索：OplusPredictiveBackController。
    //
    // 实现要点（对照 AOSP 源码验证）：
    //   1) 注册 priority 用 PRIORITY_OVERLAY（1000000）：高于任何应用级注册（Checker 禁止
    //      负 priority），必盖过 Flutter embedding 在 PRIORITY_DEFAULT 的注册，手势只到我们。
    //   2) onBackStarted/onBackProgressed/onBackCancelled 全部 no-op → 系统不播放默认动画
    //      （相册网格不再缩放抖动），也不退出沉浸模式、不弹“再次滑动返回”。
    //   3) onBackInvoked 里 popRoute()：走 Flutter 的 Navigator.maybePop（PopScope 拦截仍生效），
    //      页面弹出动画由 Flutter 正常播放。
    //   4) 需配合 Manifest android:enableOnBackInvokedCallback="true"：Android 16 的
    //      WindowOnBackInvokedDispatcher$Checker 在 flag=false 时拒绝注册。
    //
    // 注：API 34 以下不注册，维持 Flutter embedding 默认行为。
    private fun registerBackGestureInterceptor() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val dispatcher = window.getOnBackInvokedDispatcher()
        dispatcher.registerOnBackInvokedCallback(
            OnBackInvokedDispatcher.PRIORITY_OVERLAY,
            object : OnBackAnimationCallback {
                override fun onBackStarted(backEvent: BackEvent) {
                    // no-op：不播动画、不显示系统栏（保持沉浸）
                }

                override fun onBackProgressed(backEvent: BackEvent) {}

                override fun onBackCancelled() {}

                override fun onBackInvoked() {
                    // 执行返回：直接通知 Flutter（Navigator.maybePop，PopScope 仍生效）
                    flutterEngine?.navigationChannel?.popRoute()
                }
            },
        )
    }

    private fun applyHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        // 取一次 attributes，所有改动后一次性回写，避免中途回写覆盖。
        val lp = window.attributes

        // (1) 标准模式切换
        pickHighRefreshModeId()?.let { modeId -> lp.preferredDisplayModeId = modeId }

        // (2) OEM 扩展（ColorOS/OneUI 等），直接在同一 lp 上反射调用。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            invokeOemExtension(lp, "setFrameRateBoostOnTouchEnabled", true)
            invokeOemExtension(lp, "setFrameRatePowerSavingsBalanced", false)
        }

        // (3) 窗口级首选刷新率（API 21-30 语义，废弃但 ColorOS 仍读取）。
        @Suppress("DEPRECATION")
        lp.preferredRefreshRate = pickHighestRefreshRate() ?: lp.preferredRefreshRate

        window.attributes = lp
    }

    @Suppress("DEPRECATION")
    private fun pickHighRefreshModeId(): Int? {
        val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            this.display
        } else {
            windowManager.defaultDisplay
        }
        val modes = display?.supportedModes ?: return null
        if (modes.isEmpty()) return null
        val current = display.mode ?: return null
        val best = modes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxByOrNull { it.refreshRate }
            ?: return null
        return if (best.refreshRate > current.refreshRate) best.modeId else null
    }

    /** 反射调用 WindowManager.LayoutParams 上的 OEM 扩展方法；不存在则静默跳过。 */
    private fun invokeOemExtension(
        lp: WindowManager.LayoutParams,
        name: String,
        value: Boolean,
    ) {
        try {
            val m = lp.javaClass.getMethod(name, java.lang.Boolean.TYPE)
            m.invoke(lp, value)
        } catch (_: NoSuchMethodException) {
            // 非 OEM ROM，接口不存在 —— 忽略
        } catch (_: Throwable) {
            // 调用失败 —— 忽略，不影响功能
        }
    }
}
