// 动画常量 —— COUI 曲线 / 时长 / 弹簧参数（对标一加系统相册手感）
//
// 所有数值反编译自一加 13 系统相册 (com.coloros.gallery3d v16.40.22) 实测：
//   - 曲线控制点源: res/interpolator/ + res/anim/*_interpolator.xml (PathInterpolator)
//   - 时长源: res/values/integers.xml (m3_sys_motion_duration_*) + Animation.COUI.Activity
//   - 弹簧源: com.coui.appcompat...MenuViewAnimatorImpl (浮动手环 response=0.5, bounce=0.4)
//
// 统一在此定义，杜绝散落字面量。新增动画必须复用这里的常量，不要内联 magic number。

import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

// ───────────────────── COUI 曲线（一加实测控制点）─────────────────────
//
// 全部是 PathInterpolator（三阶贝塞尔），一加把 y1 固定为 0、y2 固定为 1，
// 只调 x1/x2 —— 这样曲线严格单调递增（无回弹），靠 x 控制节奏感。
// Flutter 的 Cubic(a,b,c,d) 对应 PathInterpolator(x1,y1,x2,y2)。
class AppCurves {
  AppCurves._();

  /// 缩放 / 共享元素主体（COUIMoveEaseInterpolator）。
  /// 强 ease-out：起步稍缓、快速冲到位。Hero 飞行、弹窗主体用它。
  static const couiMoveEase = Cubic(0.3, 0.0, 0.1, 1.0);

  /// alpha 渐变（COUIEaseInterpolator）= 标准 easeInOut。
  /// 用于透明度、被推页暗化。
  static const couiEase = Cubic(0.33, 0.0, 0.67, 1.0);

  /// 从底部弹起（COUIInEaseInterpolator）：极速起步、缓慢落位。
  /// 底部表单、push-up fragment。
  static const couiInEase = Cubic(0.0, 0.0, 0.1, 1.0);

  /// 向下沉降（COUIOutEaseInterpolator）：快速起步、极慢收尾。
  /// 按压回缩、收起动效。
  static const couiOutEase = Cubic(0.3, 0.0, 1.0, 1.0);

  // ── activity slide 专用（一加 Animation.COUI.Activity 实测）──

  /// 进入页位移（coui_open_slide_enter_translate_interpolator）。
  static const slideEnter = Cubic(0.3, 0.1, 0.3, 1.0);

  /// 被推页位移（coui_open_slide_exit_translate_interpolator）：视差左移。
  static const slideExit = Cubic(0.3, 0.15, 0.3, 1.0);

  /// pop 退出位移（coui_close_slide_exit_translate_interpolator）。
  static const slidePopExit = Cubic(0.25, 0.1, 0.3, 1.0);

  /// 弹窗进入（android_alert_dialog_enter）：用于居中弹窗 scale。
  static const dialogEnter = Cubic(0.3, 0.0, 0.1, 1.0);

  /// 弹窗退出（android_alert_dialog_exit）：用于居中弹窗淡出。
  static const dialogExit = Cubic(0.3, 0.0, 1.0, 1.0);
}

// ───────────────────── 时长（一加 duration token 实测）─────────────────────
//
// 源 res/values/integers.xml 的 m3_sys_motion_duration_* + 一加 coui_animation_time_*。
// 分级对应一加：activity 350、dialog 250、popup 200、micro 150。
class AppDurations {
  AppDurations._();

  /// 页面转场（一加 coui_open_slide = 350ms）。
  static const activity = Duration(milliseconds: 350);

  /// 弹窗 / 底部表单（一加 coui_center/bottom_dialog = 250ms）。
  static const dialog = Duration(milliseconds: 250);

  /// 菜单 / popup（一加 popup_in_out / abc_popup = 150–200ms）。
  static const popup = Duration(milliseconds: 200);

  /// 微交互（一加 m3_sys_motion_duration_short3 = 150ms）。
  static const micro = Duration(milliseconds: 150);

  /// [ente 对齐] 内容切换交叉淡入（albums_tab
  /// _kContentTransitionDuration = 150ms；进 easeInQuart / 出 easeOutExpo）。
  /// 排序/视图模式切换时网格内容整体 fade 过渡。
  static const enteContentSwitch = Duration(milliseconds: 150);

  /// photo viewer 飞行缩放（保持原 250ms：图加载需要时间，过快会灰屏）。
  static const flight = Duration(milliseconds: 250);

  /// photo viewer 回退（原 180ms：稍快，强调"放手即回"）。
  static const flightReverse = Duration(milliseconds: 180);
}

// ───────────────────── 弹簧（一加浮动手环实测）─────────────────────
//
// 一加 COUISpringForce 用 response(秒)/bounce(0–1) 配置，换算关系：
//   stiffness    = (2π / response)²
//   dampingRatio = 1 - bounce
// 浮动手环实测 response=0.5, bounce=0.4 → stiffness≈158, dampingRatio=0.6。
class AppSprings {
  AppSprings._();

  /// 弹性主体（弹窗/浮动手环）：可见过冲回弹。
  static const bouncy = SpringDescription(
    mass: 1,
    stiffness: 158, // (2π/0.5)² ≈ 157.91
    damping: 19, // dampingRatio 0.6 × 2√(mass·stiffness) ≈ 19.0
  );

  /// 温和（菜单展开/选中态）：轻微回弹，更克制。
  static const gentle = SpringDescription(
    mass: 1,
    stiffness: 158,
    damping: 25, // dampingRatio 0.8 × 2√158 ≈ 25.3
  );

  /// 构造一个从 [from]→[to]、带真实弹簧物理的 Simulation。
  /// [spring] 默认 bouncy；[velocity] 用于接续手势甩出速度（默认 0）。
  static SpringSimulation simulation({
    double from = 0.0,
    double to = 1.0,
    double velocity = 0,
    SpringDescription spring = bouncy,
  }) {
    return SpringSimulation(spring, from, to, velocity);
  }
}
