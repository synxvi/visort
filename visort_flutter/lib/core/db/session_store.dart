// 整理会话 store(P2)—— sort_session / sort_image / sort_decision 三表
//
// 单活跃会话模型:session 行 id 恒为 1,新扫描(saveNewSession)事务性整体
// 覆写旧会话;Run 完成或 reset 时 clear。
//
// seq 语义(与内存 LinkedHashMap 精确对齐):
//   - seq 由调用方(SessionController._seqById)分配:新 key 递增、重 decide
//     的 key 保持原 seq(LinkedHashMap 重复 put 保持首插位);
//   - 恢复时按 seq 升序重建 decisions LinkedHashMap,undo 弹末位 = 内存同语义;
//   - 插入用 conflictAlgorithm.replace(行删重插)而非 ON CONFLICT DO UPDATE
//     ——老安卓系统 SQLite(<3.24,如 Android 9 的 3.22)无 upsert 语法,
//     seq 由参数给出,REPLACE 语义下顺序信息不丢。
//
// 降级红线:同其他 store,DB 不可用全部 noop(controller 退化为纯内存现状)。

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:visort_flutter/core/config/models.dart' show FolderTemplate;
import 'package:visort_flutter/core/config/profiles_service.dart'
    show FolderDescriptor;
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/session/session_models.dart';

/// loadActive 的返回:恢复出的会话 + controller 侧重建 seq 计数所需数据。
class RestoredSession {
  const RestoredSession({
    required this.state,
    required this.seqById,
    required this.nextSeq,
  });

  final SessionState state;

  /// image_id → seq(决策插入序),恢复后 controller 继续用它对齐
  /// LinkedHashMap 的重 decide 保序语义。
  final Map<String, int> seqById;

  /// 下一个新决策的 seq = max(seq)+1(空决策为 0)。
  final int nextSeq;
}

class SessionStore {
  SessionStore(this._db);

  /// 数据库句柄(经 DatabaseService.database 幂等 getter);null = 降级 noop。
  final Future<sqflite.Database?> _db;

  static const _sessionId = 1;

  /// 新会话整体覆写(事务):清三表 → 写头行(id=1)+ images 批插 + 当前
  /// decisions 批插(initFromScan 时为空;通用起见一并保存)。
  Future<void> saveNewSession(SessionState s) async {
    try {
      final db = await _db;
      if (db == null) {
        debugPrint('[SessionStore] saveNewSession: db is NULL (degraded)');
        return;
      }
      await db.transaction((txn) async {
        await _clearAll(txn);
        await txn.insert('sort_session', {
          'id': _sessionId,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'source_dir': s.sourceDir,
          'destination_parent': s.destinationParent,
          'current_index': s.currentIndex,
          'folder_templates': jsonEncode(
              [for (final t in s.folderTemplates) t.toJson()]),
          'folders': jsonEncode([
            for (final f in s.folders)
              {'key': f.key, 'label': f.label, 'path': f.path},
          ]),
          'classify_mode': s.classifyMode,
        });
        final imgBatch = txn.batch();
        for (var i = 0; i < s.images.length; i++) {
          final img = s.images[i];
          imgBatch.insert('sort_image', {
            'session_id': _sessionId,
            'image_id': img.id,
            'seq': i,
            'root': img.root,
            'extension': img.extension,
            'display_name': img.displayName,
          });
        }
        await imgBatch.commit(noResult: true);
        final decisions = s.decisions;
        if (decisions != null && decisions.isNotEmpty) {
          final decBatch = txn.batch();
          var seq = 0;
          decisions.forEach((id, d) {
            decBatch.insert('sort_decision',
                _decisionRow(_sessionId, id, seq++, d));
          });
          await decBatch.commit(noResult: true);
        }
      });
    } catch (e, st) {
      // 写失败 = 会话退化为纯内存(现状行为),不阻塞整理。
      debugPrint('[SessionStore] saveNewSession FAILED: $e\n$st');
    }
  }

  /// 单决策写入(REPLACE 语义;seq 由 controller 分配,见类注释)。
  Future<void> upsertDecision(String imageId, Decision d, int seq) async {
    try {
      final db = await _db;
      if (db == null) {
        debugPrint('[SessionStore] upsertDecision: db is NULL (degraded)');
        return;
      }
      await db.insert('sort_decision', _decisionRow(_sessionId, imageId, seq, d),
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('[SessionStore] upsertDecision FAILED: $e');
    }
  }

  /// 撤销:删该图决策行。
  Future<void> deleteDecision(String imageId) async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.delete('sort_decision',
          where: 'session_id = ? AND image_id = ?',
          whereArgs: [_sessionId, imageId]);
    } catch (_) {}
  }

  /// 更新头行 currentIndex(decide/undo/goToIndex 后;单行 UPDATE)。
  Future<void> updateCurrentIndex(int index) async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.update('sort_session', {'current_index': index},
          where: 'id = ?', whereArgs: [_sessionId]);
    } catch (_) {}
  }

  /// 活跃会话摘要(Start 前恢复弹窗用);无会话返回 null。
  /// 单条 SQL 带子查询取 total/decided/idx,避免多次往返。
  Future<({int total, int decided, int currentIndex})?> summary() async {
    try {
      final db = await _db;
      if (db == null) return null;
      final rows = await db.rawQuery('''
        SELECT s.current_index AS idx,
               (SELECT COUNT(*) FROM sort_image WHERE session_id = s.id) AS total,
               (SELECT COUNT(*) FROM sort_decision WHERE session_id = s.id) AS decided
        FROM sort_session s WHERE s.id = ? LIMIT 1
      ''', [_sessionId]);
      if (rows.isEmpty) return null;
      return (
        total: (rows.first['total'] as int?) ?? 0,
        decided: (rows.first['decided'] as int?) ?? 0,
        currentIndex: (rows.first['idx'] as int?) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 恢复会话(头 + images + decisions);无会话/解析失败返回 null。
  /// 未知 action 或 folders JSON 损坏时整体放弃(宁可不恢复也不错恢复)。
  Future<RestoredSession?> loadActive() async {
    try {
      final db = await _db;
      if (db == null) return null;
      final heads =
          await db.query('sort_session', where: 'id = ?', whereArgs: [_sessionId]);
      if (heads.isEmpty) return null;
      final head = heads.first;

      final imageRows = await db.query('sort_image',
          where: 'session_id = ?', whereArgs: [_sessionId], orderBy: 'seq ASC');
      if (imageRows.isEmpty) return null; // 空扫描的会话无恢复价值

      final decisionRows = await db.query('sort_decision',
          where: 'session_id = ?', whereArgs: [_sessionId], orderBy: 'seq ASC');

      // images 重建(relativePath = image_id)。
      final images = [
        for (final r in imageRows)
          ImageRef(
            root: r['root'] as String,
            relativePath: r['image_id'] as String,
            extension: r['extension'] as String,
            displayName: r['display_name'] as String?,
          ),
      ];

      // decisions 按 seq 重建(map literal 默认即 LinkedHashMap,保插入序)。
      final decisions = <String, Decision>{};
      final seqById = <String, int>{};
      var maxSeq = -1;
      for (final r in decisionRows) {
        final id = r['image_id'] as String;
        final action = _actionFromName(r['action'] as String?);
        if (action == null) return null; // 未知动作:数据异常,放弃恢复
        decisions[id] = Decision(
          action: action,
          destKey: r['dest_key'] as String?,
          destLabel: r['dest_label'] as String?,
          destPath: r['dest_path'] as String?,
        );
        final seq = (r['seq'] as int?) ?? 0;
        seqById[id] = seq;
        if (seq > maxSeq) maxSeq = seq;
      }

      // folderTemplates 复用现有 codec;folders 手写 key/label/path。
      final templatesJson =
          jsonDecode(head['folder_templates'] as String) as List;
      final folderTemplates = [
        for (final t in templatesJson)
          FolderTemplate.fromJson(t as Map<String, dynamic>),
      ];
      final foldersJson = jsonDecode(head['folders'] as String) as List;
      final folders = [
        for (final f in foldersJson)
          FolderDescriptor(
            key: f['key'] as String,
            label: f['label'] as String,
            path: f['path'] as String,
          ),
      ];

      return RestoredSession(
        state: SessionState(
          sourceDir: head['source_dir'] as String? ?? '',
          destinationParent: head['destination_parent'] as String? ?? '',
          images: images,
          currentIndex: (head['current_index'] as int?) ?? 0,
          folderTemplates: folderTemplates,
          folders: folders,
          decisions: decisions,
          // v5 前的旧会话无此列(null)——UI 回退当前配置判断。
          classifyMode: head['classify_mode'] as String?,
        ),
        seqById: seqById,
        nextSeq: maxSeq + 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// 清空会话三表(Run 完成 reset / 新扫描由 saveNewSession 事务内清理)。
  Future<void> clear() async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.transaction((txn) async => _clearAll(txn));
    } catch (_) {}
  }

  static Future<void> _clearAll(sqflite.DatabaseExecutor txn) async {
    await txn.delete('sort_session');
    await txn.delete('sort_image');
    await txn.delete('sort_decision');
  }

  static Map<String, Object?> _decisionRow(
      int sessionId, String imageId, int seq, Decision d) {
    return {
      'session_id': sessionId,
      'image_id': imageId,
      'seq': seq,
      'action': d.action.name,
      'dest_key': d.destKey,
      'dest_label': d.destLabel,
      'dest_path': d.destPath,
    };
  }

  static DecisionAction? _actionFromName(String? name) {
    if (name == null) return null;
    for (final a in DecisionAction.values) {
      if (a.name == name) return a;
    }
    return null;
  }
}
