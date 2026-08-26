# Flutter SDK 本地补丁

直接改在 SDK 源码（`~/Dev/Env/flutter`）里的自定义修复，**每次 `flutter upgrade` 会被抹掉，升级后必须重新应用**。

## 使用方法

```bash
cd ~/Dev/Env/flutter
git apply <本项目>/flutter-sdk-patches/heroes-pop-flight_vX.YY.patch
```

若 `git apply` 报上下文冲突（SDK 版本变了），用 `git apply -3` 三方合并或按 patch 里的注释手工移植。

## 补丁清单

### heroes-pop-flight_v3.44.patch（基于 3.44 导出）

- 文件：`packages/flutter/lib/src/widgets/heroes.dart`
- 修复：程序化 pop（返回键 / 系统返回手势 / 显式 `Navigator.pop`）从不触发 Hero 飞行动画——`didChangeTop` 在 pop 动画结束后才触发（`fromRoute.animation.value == 0` 直接 return），`didStartUserGesture` 又找不到正在 pop 的 route。
- 做法：hook `didPop`（pop 时同步触发，动画尚未 reverse），在 reverse 开始时启动 flight；`didChangeTop` 里对已由 patch 启动的 flight 跳过 divert（否则飞行层闪一下）。
- 附带：`HeroController.onPopFlightStarted` 静态钩子，app 侧把 chrome overlay entry 重插到飞行层之上（单 viewer 路由）。

### heroes_3.47.1_patched.dart（完整归档，CI 用）

- 官方 3.47.1 的 `heroes.dart` + 上述补丁的完整产物（1224 行），与本机
  `~/Dev/Env/flutter`（3.47.1 + patch）逐字节一致（reverse-check 验证）。
- **CI（.github/workflows/release.yml）用直接覆盖本文件**，不再走
  `patch`/`git apply`——缓存 SDK 的「已应用」状态检测在 CI 上反复翻车
  （GNU patch 对已应用补丁做 reverse --dry-run 会自动换向并 exit 1；
  forward 对缓存态又误报 previously applied），覆盖是唯一确定性方案。
- **SDK 升级时**：本机重新应用补丁后，必须重新归档：
  `cp ~/Dev/Env/flutter/packages/flutter/lib/src/widgets/heroes.dart \
     flutter-sdk-patches/heroes_<新版本>_patched.dart` 并同步改 workflow
  里的文件名（两处 linux cp + 一处 windows Copy-Item）。
