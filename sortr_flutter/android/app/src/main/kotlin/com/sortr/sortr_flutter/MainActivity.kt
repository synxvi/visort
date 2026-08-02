package com.sortr.sortr_flutter

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
import com.sortr.sortr_flutter.mediastore.MediaStorePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注册 MediaStore MethodChannel + EventChannel plugin（sortr/mediastore）
        flutterEngine.plugins.add(MediaStorePlugin())
        // SAF plugin 已移除（MediaStore 取代）。非媒体文件场景如需恢复，需重新引入 saf 包。
        // 「回桌面」通道：首页（根路由）右滑返回时 Dart 调 moveTaskToBack，
        // 等效 Home 键（task 保留后台，不 finish——finish 会从最近任务移除应用）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sortr/app")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveTaskToBack") {
                    runOnUiThread { moveTaskToBack(true) }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    // 在窗口属性创建阶段注入高刷设置。onAttachedToWindow 是窗口已 attach 但
    // 首帧绘制前的稳定时机，对 preferredDisplayModeId 生效足够早；比 onPostCreate
    // 更可靠（onPostCreate 时部分 ROM 已锁定 mode）。
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        applyHighRefreshRate()
        applyFixedFrameRate()
        registerBackGestureInterceptor()
    }

    // 固定帧率声明：Surface.setFrameRate(FIXED_SOURCE)。
    //
    // 背景（2026-08 实测，OnePlus/ColorOS 16）：SORTR 双指捏合缩放时刷新率不稳定——
    // 开发者选项“全局显示屏幕刷新率”显示 1/30/120 跳变，系统相册则稳定 120。
    // 原因：ColorOS 智能帧率根据 app 帧提交节奏动态切 display mode；SORTR 从未显式
    // 声明渲染帧率（SurfaceFlinger layer 无 frameRate 字段），提交节奏一波动就降档，
    // 形成低档/高档震荡。
    // 修复：对渲染 surface 声明 FIXED_SOURCE 帧率 = 设备最高刷新率，明确告知系统
    // “本 surface 按该帧率渲染”，display 保持高刷不随提交节奏降档（与系统相册一致）。
    // 代价：app 前台时 display 始终高刷（LTPO 不降），耗电略增；用户已开全局高刷，可接受。
    private fun applyFixedFrameRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val rate = pickHighestRefreshRate() ?: return
        val surfaceView = findSurfaceView(window.decorView) ?: return
        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                declareFrameRate(holder)
            }

            override fun surfaceChanged(
                holder: SurfaceHolder,
                format: Int,
                width: Int,
                height: Int,
            ) {
                // surface 尺寸/格式变化后 SF 可能重置 layer 帧率声明，重新声明一次。
                declareFrameRate(holder)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })
    }

    private fun declareFrameRate(holder: SurfaceHolder) {
        val rate = pickHighestRefreshRate() ?: return
        try {
            // ⚠️ FRAME_RATE_COMPATIBILITY_AT_LEAST 关键（2026-08 实测，ColorOS 16）：
            // 之前用 FIXED_SOURCE（SF dump 显示 ExactOrMultiple）——其语义允许
            // “声明帧率的约数”（120 的约数含 60/30/24），ColorOS 智能帧率在 app
            // 提交节奏波动时合法降档到 30 且不回升（引擎 120fps 提交、display 120Hz，
            // 但 SF 合成 30，开发者选项“显示屏幕刷新率”显示 30）。
            // AT_LEAST = display 帧率至少为声明值（120 为设备上限 → 锁死 120 不降档）。
            // 设备 ROM 无 4 参 setFrameRate（无 FrameRateCategory），3 参即可。
            holder.surface.setFrameRate(
                rate,
                Surface.FRAME_RATE_COMPATIBILITY_AT_LEAST,
                Surface.CHANGE_FRAME_RATE_ALWAYS,
            )
        } catch (e: Throwable) {
            // 个别 OEM 实现差异——忽略，回退系统默认策略
            android.util.Log.w("SortrFPS", "setFrameRate failed: $e")
        }
    }

    /** 设备支持的最高刷新率（同分辨率下最高的那个 mode 的刷新率）。 */
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

    // 开启高刷新率（90/120Hz）。多层手段叠加，覆盖不同 OEM 的调度策略：
    //
    //   1) preferredDisplayModeId：标准 API。对系统默认 mode 为 60Hz 的设备能切到高刷。
    //   2) setFrameRateBoostOnTouchEnabled(true) / setFrameRatePowerSavingsBalanced(true)：
    //      OPPO/ColorOS、三星等 OEM 在 LayoutParams 上扩展的接口，请求触摸/滚动时升频到高刷。
    //      （API 31+，低版本为 no-op。）
    //
    // 实测：仅 preferredDisplayModeId 在 ColorOS 上常被忽略，app surface 仍报告
    // "0.00 Hz / NoPreference" 而被压在 60Hz；叠加 OEM 扩展后系统才放行 120Hz。
    // 参考：flutter/flutter#62354（高刷支持）、#90639（部分 OEM 120Hz 不生效）。
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

        window.attributes = lp
    }

    /** 在同分辨率下挑刷新率最高的 display mode id（不同分辨率会改 viewport，不取）。 */
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
