// SQLite 底座(P0)—— 数据级持久化的 open / 版本迁移 / 降级
//
// 设计要点(见 docs/SQLITE_ROADMAP.md §4 P0):
//   - 安卓: sqflite 默认 method-channel factory(系统 SQLite);
//     Windows: databaseFactory = databaseFactoryFfi(原生库由 sqlite3_flutter_libs 捆绑)。
//   - 降级红线: open/migrate 全程 try-catch,失败保持 _db = null——所有 store
//     拿到 null 后 noop,app 行为回到无持久化现状,永不因 DB 故障崩溃。
//   - 时序: main() 以 unawaited 预热 init();store 一律经 [database] getter
//     (幂等,未初始化会自行 await init),与预热双保险,无竞态。
//   - 迁移: 手写 onCreate/onUpgrade,无 codegen(项目铁律)。每阶段升一版,
//     升级路径在此追加,不改动历史分支。

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库版本史(与 docs/SQLITE_ROADMAP.md §3 一一对应):
///   v1 (P1): bucket_snapshot / bucket_photo —— 相册桶快照,替代 visort_snap_* prefs
const int kDbVersion = 1;

final databaseServiceProvider =
    Provider<DatabaseService>((ref) => DatabaseService());

class DatabaseService {
  sqflite.Database? _db;
  bool _initAttempted = false;

  /// 打开数据库并跑到最新版本。幂等;main() 启动预热调用,失败静默降级。
  Future<void> init() async {
    if (_initAttempted) return;
    _initAttempted = true;
    try {
      // 桌面端 ffi:Win/Linux 无系统 SQLite,原生库随 app 捆绑。
      // 安卓不动 factory——默认 method-channel 走系统 SQLite。
      if (Platform.isWindows || Platform.isLinux) {
        sqflite.databaseFactory = databaseFactoryFfi;
      }
      final dir = await getApplicationSupportDirectory();
      _db = await sqflite.databaseFactory.openDatabase(
        p.join(dir.path, 'visort.db'),
        options: sqflite.OpenDatabaseOptions(
          version: kDbVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    } catch (_) {
      // 降级红线:保持 _db = null(store 全部 noop)。
    }
  }

  /// 当前数据库句柄;未初始化/初始化失败时先补一次 init 再返回(可能为 null)。
  /// store 侧统一 `await db` 后判空跳过,不抛异常。
  Future<sqflite.Database?> get database async {
    if (!_initAttempted) await init();
    return _db;
  }

  static Future<void> _onCreate(sqflite.Database db, int version) async {
    // 全新安装:直接建到最新版全量表。
    await createAll(db);
  }

  static Future<void> _onUpgrade(
      sqflite.Database db, int oldVersion, int newVersion) async {
    // v1 起步,暂无升级路径。P2 起在此追加:
    //   if (oldVersion < 2) { await db.execute('CREATE TABLE sort_session ...'); ... }
  }

  /// 建当前版本的全部表(测试的内存库复用同一 schema,保证不漂移)。
  /// 升版时此方法更新为「最新全量」,onUpgrade 补历史增量。
  static Future<void> createAll(sqflite.Database db) async {
    // ── v1 (P1): 相册桶快照 ──
    // snapshot 行携带分页游标与排序(快照总是某排序下的列表前缀);
    // photo 行复用 MsImageInfo 字段,seq 保列表序(恢复顺序)。
    await db.execute('''
      CREATE TABLE bucket_snapshot (
        bucket_id   TEXT PRIMARY KEY,
        sort_by     TEXT NOT NULL,
        asc         INTEGER NOT NULL,
        next_cursor TEXT,
        updated_at  INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE bucket_photo (
        bucket_id       TEXT NOT NULL,
        id              TEXT NOT NULL,
        seq             INTEGER NOT NULL,
        name            TEXT NOT NULL,
        size            INTEGER NOT NULL,
        mime            TEXT NOT NULL,
        date_added_ms   INTEGER NOT NULL,
        date_modified_ms INTEGER NOT NULL,
        is_favorite     INTEGER NOT NULL DEFAULT 0,
        is_trashed      INTEGER NOT NULL DEFAULT 0,
        date_trashed_ms INTEGER NOT NULL DEFAULT 0,
        width           INTEGER NOT NULL DEFAULT 0,
        height          INTEGER NOT NULL DEFAULT 0,
        is_hdr          INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bucket_id, id)
      ) WITHOUT ROWID
    ''');
  }
}
