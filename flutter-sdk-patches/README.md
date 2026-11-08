# Flutter SDK 本地补丁

直接改在 SDK 源码（`~/Dev/Env/flutter`）里的自定义修复，**每次 `flutter upgrade` 会被抹掉，升级后必须重新应用**。

## 使用方法

```bash
cd ~/Dev/Env/flutter
git apply <本项目>/flutter-sdk-patches/heroes-pop-flight_vX.YY.patch
```

若 `git apply` 报上下文冲突（SDK 版本变了），用 `git apply -3` 三方合并或按 patch 里的注释手工移植。

## 补丁清单

### heroes-pop-flight_v3.47.patch（基于 3.47.1 导出）

- 文件：`packages/flutter/lib/src/widgets/heroes.dart`
- 修复 1：程序化 pop（返回键 / 系统返回手势 / 显式 `Navigator.pop`）从不触发 Hero 飞行动画——`didChangeTop` 在 pop 动画结束后才触发（`fromRoute.animation.value == 0` 直接 return），`didStartUserGesture` 又找不到正在 pop 的 route。
- 做法：hook `didPop`（pop 时同步触发，动画尚未 reverse），在 reverse 开始时启动 flight；`didChangeTop` 里对已由 patch 启动的 flight 跳过 divert（否则飞行层闪一下）。
- 附带：`HeroController.onPopFlightStarted` 静态钩子，app 侧把 chrome overlay entry 重插到飞行层之上（单 viewer 路由）。
- 修复 2（2026-09）：viewer 连续翻多张后返回，pop flight 同步构建 manifest 读的是上一帧 element 树——目标 cell 尚未构建（app 的网格重定位冲刷与本启动同帧，SliverList band 重建要等 layout）→ manifest 为空 → 返回「淡出」。
- 做法：启动前同步探测 `_popHeroesMissing`（from 的 hero 在 to 中缺位）或 app 置位 `HeroController.deferNextPopFlight`（网格将 jumpTo，即使 hero 在 cacheExtent 内也是旧 bounds）→ 延到帧末 postFrame 启动（layout 已完成、bounds 正确；defer 期间 from hero 保持显示，pop 起步帧无感）。手势返回分支（didStartUserGesture 的同步路径）同判同治。to hero 就位的常态（未翻页首屏）保持同步启动（已验证的零闪烁路径）。
- 修复 3（2026-11）：同步启动路径（`didPop` 的 reverse 分支、`_armPopPlaceholderCleanup` 的动画瞬完分支、`didStartUserGesture` 手势分支）都在 Navigator 事务锁（`_debugLocked`）窗口内执行——飞行启动中任何异常（典型：app 路由子树内同 tag 重复 Hero 使 `Hero._allHeroesFor` 断言炸掉）会穿过 pop 的 flush，跳过 `NavigatorState.pop` 里 assert 块中的解锁语句 → 锁永久卡死，此后每帧 `NavigatorState.build` 抛 `'!_debugLocked'` 红屏、导航器整体不可用（2026-11 模拟器实证 + 全栈捕获）。
- 做法：`_startHeroTransition` 拆为护栏外壳 + `_startHeroTransitionBody`（方法体原样），外壳 try/catch 经 `_reportFlightError` 统一 `FlutterError.reportError` 后吞掉——飞行失败降级为纯淡入淡出，Navigator 状态机不受影响；`onPopFlightStarted`（同步/deferred 两处）与 placeholder cleanup 的 `visitChildElements` 同样包护。app 侧根因（快整页源/目标列表同相册 tile 同 tag 重复）由 `home_screen_android.dart` 的 Hero 模式互斥门控另行根治，本护栏防任何未来回归。

### heroes_3.47.1_patched.dart（完整归档，CI 用）

- 官方 3.47.1 的 `heroes.dart` + 上述补丁的完整产物（1438 行，2026-11 修复 3 后），与本机
  `~/Dev/Env/flutter`（3.47.1 + patch）逐字节一致（reverse-check 验证）。
- **CI（.github/workflows/release.yml）用直接覆盖本文件**，不再走
  `patch`/`git apply`——缓存 SDK 的「已应用」状态检测在 CI 上反复翻车
  （GNU patch 对已应用补丁做 reverse --dry-run 会自动换向并 exit 1；
  forward 对缓存态又误报 previously applied），覆盖是唯一确定性方案。
- **SDK 升级时**：本机重新应用补丁后，必须重新归档：
  `cp ~/Dev/Env/flutter/packages/flutter/lib/src/widgets/heroes.dart \
     flutter-sdk-patches/heroes_<新版本>_patched.dart` 并同步改 workflow
  里的文件名（两处 linux cp + 一处 windows Copy-Item）。
