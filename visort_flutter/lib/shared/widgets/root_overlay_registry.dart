// root Overlay 模态浮层登记表（2026-09 审查 F8 真机反馈补丁）。
//
// 为什么需要：挂 root Overlay 的模态浮层（confirm_sheet / profile_dropdown）
// 感知不到 shell 的 IndexedStack 切页——一级页（相册/整理/设置…）全在根
// 路由 `/` 内，没有路由动画可监听（ModalRoute 监听只对 push 出来的页有
// 效）。浮层残留的后果是模态 scrim 吞掉全屏点击（真机实证：设置页弹窗
// 返回切页后，首页相册点不动）。
//
// 收口方式：shell 在「系统返回」与「切页」两处调用 [dismissTopRootOverlay]——
// 返回 = 先关最上层浮层（安卓模态标准行为，本次返回被浮层消费）；
// 切页（抽屉/底部导航）= 浮层随旧视图一起关。路由动画监听（push 页）仍
// 并存生效，两层防护。

/// 叠放次序 = 登记次序（后弹在上）；close 幂等，已关浮层在 close 时注销。
final List<void Function()> _rootOverlayClosers = [];

/// 浮层 open 时登记关闭器；浮层自身 close 时经返回的注销器移除。
void registerRootOverlayCloser(void Function() closer) =>
    _rootOverlayClosers.add(closer);

void unregisterRootOverlayCloser(void Function() closer) =>
    _rootOverlayClosers.remove(closer);

/// 关闭最上层浮层。有浮层被关返回 true（shell 据此拦下本次返回）。
bool dismissTopRootOverlay() {
  if (_rootOverlayClosers.isEmpty) return false;
  _rootOverlayClosers.removeLast()();
  return true;
}
