// SAF PoC demo 页 —— 里程碑 A0 验证用
//
// 验证目标（roadmap A0 验收点）：
//   1. 选目录 → 调 ACTION_OPEN_DOCUMENT_TREE，返回 tree URI
//   2. 扫描 → 列出 tree 下的图片名（纯文本）
//   3. 持久化 → 重启 app 后 persistedUriPermissions 仍包含上次 URI
//
// 非正式 UI：仅安卓 + 仅用于 A0 PoC，里程碑 A2 后将被 sort_screen 替代。
// 通过 Setup 屏的隐藏入口（仅 Android 显示）进入。

import 'package:flutter/material.dart';

import '../../core/fs/saf_channel.dart';

class SafDemoScreen extends StatefulWidget {
  const SafDemoScreen({super.key});

  @override
  State<SafDemoScreen> createState() => _SafDemoScreenState();
}

class _SafDemoScreenState extends State<SafDemoScreen> {
  static const _channel = SafChannel();

  String? _treeUri;
  List<SafImageInfo> _images = const [];
  List<SafPermissionInfo> _perms = const [];
  // A1 验证状态
  List<String> _subdirs = const [];
  String? _metaText;
  String? _bytesText;
  String? _opResult;
  String? _error;
  bool _busy = false;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri = await _channel.pickDirectory();
      final images = await _channel.scanImages(uri, max: 200);
      final perms = await _channel.persistedUriPermissions();
      setState(() {
        _treeUri = uri;
        _images = images;
        _perms = perms;
      });
    } on SafCancelledException {
      // 用户取消，静默
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescan() async {
    final uri = _treeUri;
    if (uri == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final images = await _channel.scanImages(uri, max: 200);
      final perms = await _channel.persistedUriPermissions();
      setState(() {
        _images = images;
        _perms = perms;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshPerms() async {
    setState(() => _busy = true);
    try {
      final perms = await _channel.persistedUriPermissions();
      setState(() => _perms = perms);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ──────────── A1 验证方法 ────────────

  Future<void> _testListSubdirs() async {
    final uri = _treeUri;
    if (uri == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final dirs = await _channel.listSubdirs(uri);
      setState(() => _subdirs = dirs);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testReadMeta() async {
    final uri = _treeUri;
    if (uri == null || _images.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final meta = await _channel.readMeta(uri, _images.first.docId);
      setState(() => _metaText =
          '${meta.name} | ${meta.size} B | ${DateTime.fromMillisecondsSinceEpoch(meta.modifiedMs)}');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testReadBytes() async {
    final uri = _treeUri;
    if (uri == null || _images.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final bytes = await _channel.readBytes(uri, _images.first.docId, maxBytes: 64);
      setState(() => _bytesText =
          '前 ${bytes.length} 字节: ${bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}...');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testDelete() async {
    final uri = _treeUri;
    if (uri == null || _images.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final ok = await _channel.delete(uri, _images.first.docId);
      setState(() {
        _opResult = 'delete ${ok ? "成功" : "失败"}';
        if (ok) _images = _images.sublist(1); // 从列表移除已删的
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161616),
        foregroundColor: const Color(0xFFF0F0F0),
        title: const Text('SAF PoC Demo (A0)'),
      ),
      body: _busy
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFE8FF47)),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionButtons(),
                if (_error != null) _sectionError(),
                if (_treeUri != null) _sectionTreeUri(),
                _sectionPerms(),
                if (_treeUri != null) _sectionImages(),
                if (_subdirs.isNotEmpty) _sectionSubdirs(),
                if (_metaText != null) _sectionResult('A1 readMeta', _metaText!, const Color(0xFFFF6B35)),
                if (_bytesText != null) _sectionResult('A1 readBytes', _bytesText!, const Color(0xFFFF6B35)),
                if (_opResult != null) _sectionResult('A1 操作结果', _opResult!, const Color(0xFFFF3B3B)),
              ],
            ),
    );
  }

  Widget _sectionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE8FF47),
            foregroundColor: const Color(0xFF0D0D0D),
          ),
          onPressed: _pick,
          child: const Text('1. 选择目录 + 扫描'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFE8FF47),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: _treeUri == null ? null : _rescan,
          child: const Text('重新扫描'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF3BFF8A),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: _refreshPerms,
          child: const Text('刷新持久化授权'),
        ),
        // A1 验证按钮
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF6B35),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: _treeUri == null ? null : _testListSubdirs,
          child: const Text('A1: 列子目录'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF6B35),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: (_treeUri == null || _images.isEmpty) ? null : _testReadMeta,
          child: const Text('A1: 读元信息'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF6B35),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: (_treeUri == null || _images.isEmpty) ? null : _testReadBytes,
          child: const Text('A1: 读字节'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF3B3B),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          onPressed: (_treeUri == null || _images.isEmpty) ? null : _testDelete,
          child: const Text('A1: 删除首图'),
        ),
      ],
    );
  }

  Widget _sectionError() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B3B).withValues(alpha: 0.1),
        border: Border.all(color: const Color(0xFFFF3B3B)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _error!,
        style: const TextStyle(color: Color(0xFFFF6060), fontFamily: 'SpaceMono'),
      ),
    );
  }

  Widget _sectionTreeUri() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选中的 tree URI',
            style: TextStyle(color: Color(0xFFE8FF47), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          SelectableText(
            _treeUri!,
            style: const TextStyle(color: Color(0xFFF0F0F0), fontFamily: 'SpaceMono', fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionPerms() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '持久化授权（${_perms.length} 条）—— 重启 app 后仍应存在',
            style: const TextStyle(color: Color(0xFF3BFF8A), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (_perms.isEmpty)
            const Text('(空)', style: TextStyle(color: Color(0xFF666666)))
          else
            ..._perms.map((p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${p.isReadPermission ? "R" : "-"}${p.isWritePermission ? "W" : "-"}  ${p.uri}',
                    style: const TextStyle(
                      color: Color(0xFFF0F0F0),
                      fontFamily: 'SpaceMono',
                      fontSize: 11,
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _sectionImages() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '扫描结果（${_images.length} 张图片）',
            style: const TextStyle(color: Color(0xFFE8FF47), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (_images.isEmpty)
            const Text('该目录下无图片', style: TextStyle(color: Color(0xFF666666)))
          else
            ..._images.take(50).map((img) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    '${img.name}  (${img.size ~/ 1024} KB, ${img.mime})',
                    style: const TextStyle(
                      color: Color(0xFFF0F0F0),
                      fontFamily: 'SpaceMono',
                      fontSize: 11,
                    ),
                  ),
                )),
          if (_images.length > 50)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '... 还有 ${_images.length - 50} 张未显示',
                style: const TextStyle(color: Color(0xFF666666), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionSubdirs() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A1 listSubdirs（${_subdirs.length} 个）',
            style: const TextStyle(color: Color(0xFFFF6B35), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._subdirs.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text('📁 $d',
                    style: const TextStyle(color: Color(0xFFF0F0F0), fontFamily: 'SpaceMono', fontSize: 11)),
              )),
        ],
      ),
    );
  }

  Widget _sectionResult(String title, String content, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          SelectableText(content,
              style: const TextStyle(color: Color(0xFFF0F0F0), fontFamily: 'SpaceMono', fontSize: 12)),
        ],
      ),
    );
  }
}
