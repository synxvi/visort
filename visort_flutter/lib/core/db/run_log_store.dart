// Run 历史 store(P3)—— run_log 表
//
// RunController.run 结束写一行审计摘要:完成时间 + moved/deleted/skipped
// 计数 + errors JSON。默认只写表(路线图:UI 入口后议);recent() 供测试
// 与未来 UI 查询。只追加不更新——历史就是历史。
//
// session_id 恒写 1(单活跃会话模型):Run 完成时 sort_session 尚在;之后
// 新扫描覆写/清理会话表,日志行退化为纯摘要,表设计允许该悬挂。
//
// 降级红线:同其他 store,DB 不可用全部 noop(Run 结果不受影响)。

import 'dart:convert';

import 'package:sqflite/sqflite.dart' as sqflite;

/// 一条 Run 历史记录(run_log 行)。
class RunLogEntry {
  const RunLogEntry({
    required this.finishedAt,
    this.sessionId,
    required this.moved,
    required this.deleted,
    required this.skipped,
    this.errors = const [],
  });

  /// 完成时间(epoch ms)。
  final int finishedAt;
  final int? sessionId;
  final int moved;
  final int deleted;
  final int skipped;

  /// {file, reason} 列表,与 RunResults.errors 同形。
  final List<({String file, String reason})> errors;
}

class RunLogStore {
  RunLogStore(this._db);

  /// 数据库句柄(经 DatabaseService.database 幂等 getter);null = 降级 noop。
  final Future<sqflite.Database?> _db;

  /// 单活跃会话恒为 1(与 SessionStore._sessionId 同源语义)。
  static const _sessionId = 1;

  /// Run 结束追加一条历史。时间在写入时取(调用方无需传)。
  Future<void> insert({
    required int moved,
    required int deleted,
    required int skipped,
    List<({String file, String reason})> errors = const [],
  }) async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.insert('run_log', {
        'session_id': _sessionId,
        'finished_at': DateTime.now().millisecondsSinceEpoch,
        'moved': moved,
        'deleted': deleted,
        'skipped': skipped,
        'errors': _encodeErrors(errors),
      });
    } catch (_) {
      // 审计日志写失败不影响 Run 结果。
    }
  }

  /// 最近 limit 条(新→旧)。测试与未来 UI 入口用。
  Future<List<RunLogEntry>> recent({int limit = 20}) async {
    try {
      final db = await _db;
      if (db == null) return const [];
      final rows = await db.query('run_log',
          orderBy: 'id DESC', limit: limit);
      return [for (final r in rows) _entryFromRow(r)];
    } catch (_) {
      return const [];
    }
  }

  /// 清空历史(目前仅测试用;保留入口避免未来 UI 需要 delete 全表重建)。
  Future<void> clear() async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.delete('run_log');
    } catch (_) {}
  }

  /// errors 编解码:手写 codec(无 codegen 铁律),file/reason 全名键。
  static String _encodeErrors(List<({String file, String reason})> errors) {
    return jsonEncode([
      for (final e in errors) {'file': e.file, 'reason': e.reason},
    ]);
  }

  static List<({String file, String reason})> _decodeErrors(String? json) {
    if (json == null || json.isEmpty) return const [];
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>)
          (file: e['file'] as String? ?? '', reason: e['reason'] as String? ?? ''),
    ];
  }

  static RunLogEntry _entryFromRow(Map<String, Object?> r) {
    return RunLogEntry(
      finishedAt: (r['finished_at'] as int?) ?? 0,
      sessionId: r['session_id'] as int?,
      moved: (r['moved'] as int?) ?? 0,
      deleted: (r['deleted'] as int?) ?? 0,
      skipped: (r['skipped'] as int?) ?? 0,
      errors: _decodeErrors(r['errors'] as String?),
    );
  }
}
