// SQLite 底座(P0)—— 数据级持久化的 open
//
// 设计要点(见 docs/SQLITE_ROADMAP.md §4 P0):
//   - 安卓: sqflite 默认 method-channel factory(系统 SQLite);
//     Windows: databaseFactory = databaseFactoryFfi(原生库由 sqlite3_flutter_libs 捆绑)。
//   - 降级红线: open 全程 try-catch,失败保持 _db = null——所有 store
//     拿到 null 后 noop,app 行为回到无持久化现状,永不因 DB 故障崩溃。
//   - 时序: main() 以 unawaited 预热 init();store 一律经 [database] getter
//     (幂等,未初始化会自行 await init),与预热双保险,无竞态。
//   - 版本策略(2026-08 简化): 无存量用户,每次构建 DB 均为初始状态,
//     不维护迁移路径——schema 变更直接改 [createAll] 全量 DDL 并升
//     kDbVersion;老版本库由 sqflite 默认 onDowngrade(删库重建)兜底。
//     (历史教训: v5 曾把新列写进 _createSortTables 又在 onUpgrade 里
//     ALTER 同名列, v1/v2 库升级必炸 duplicate column——迁移路径整体
//     废弃后此类问题不复存在。)

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库版本。无存量用户策略(见文件头):schema 变更时直接升此号并
/// 改 createAll 全量 DDL,不写迁移——高版本老库降级由 sqflite 默认
/// onDowngrade(删库重建)处理。
const int kDbVersion = 1;

final databaseServiceProvider =
    Provider<DatabaseService>((ref) => DatabaseService());

class DatabaseService {
  sqflite.Database? _db;

  /// 初始化 Future(幂等锚点):首次调用启动 _open,后续所有调用共享
  /// 同一个 Future——无论 main 的预热与 store 构造谁先谁后,大家等的是
  /// 同一次初始化。曾用「_initAttempted 标志」版:进行中时后来者立即
  /// 返回(拿到 null),store 把 null Future 永久快照——冷启动首帧构造
  /// 的 store 全废(会话决策不落盘),真机"读时好写时坏"的根因。
  Future<void>? _initFuture;

  /// 打开数据库并跑到最新版本。幂等;main() 启动预热调用,失败静默降级。
  Future<void> init() => _initFuture ??= _open();

  Future<void> _open() async {
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
        ),
      );
    } catch (_) {
      // 降级红线:保持 _db = null(store 全部 noop)。
    }
  }

  /// 当前数据库句柄;等待共享初始化完成后返回(失败降级为 null)。
  /// store 侧统一 `await db` 后判空跳过,不抛异常。
  Future<sqflite.Database?> get database async {
    await init();
    return _db;
  }

  static Future<void> _onCreate(sqflite.Database db, int version) async {
    // 全新安装:直接建到最新版全量表。
    await createAll(db);
  }


  /// 建当前版本的全部表(测试的内存库复用同一 schema,保证不漂移)。
  /// 升版时此方法更新为「最新全量」并升 kDbVersion,无迁移路径。
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
    // ── v2: HDR 检测缓存 ──
    await db.execute('''
      CREATE TABLE hdr_cache (
        id               TEXT PRIMARY KEY,
        date_modified_ms INTEGER NOT NULL,
        is_hdr           INTEGER NOT NULL
      ) WITHOUT ROWID
    ''');
    // ── v3 (P2): 整理会话 ──
    await _createSortTables(db);
    // ── v4 (P3): Run 历史 ──
    await _createRunLogTable(db);
  }

  /// v3 会话三表(createAll 全量建表用,保证 schema 一致)。
  ///
  /// session 行 id 恒为 1(单活跃会话:新扫描整体覆写旧的);image_id 桌面=
  /// 相对路径、安卓=MediaStore _ID(跨重启稳定);decision.seq 为决策插入序
  /// (恢复时按 seq 重建 LinkedHashMap,undo 弹末位)。
  static Future<void> _createSortTables(sqflite.Database db) async {
    await db.execute('''
      CREATE TABLE sort_session (
        id                INTEGER PRIMARY KEY,
        created_at        INTEGER NOT NULL,
        source_dir        TEXT NOT NULL,
        destination_parent TEXT NOT NULL,
        current_index     INTEGER NOT NULL,
        folder_templates  TEXT NOT NULL,
        folders           TEXT NOT NULL,
        classify_mode     TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE sort_image (
        session_id  INTEGER NOT NULL,
        image_id    TEXT NOT NULL,
        seq         INTEGER NOT NULL,
        root        TEXT NOT NULL,
        extension   TEXT NOT NULL,
        display_name TEXT,
        PRIMARY KEY (session_id, image_id)
      ) WITHOUT ROWID
    ''');
    await db.execute('''
      CREATE TABLE sort_decision (
        session_id INTEGER NOT NULL,
        image_id   TEXT NOT NULL,
        seq        INTEGER NOT NULL,
        action     TEXT NOT NULL,
        dest_key   TEXT,
        dest_label TEXT,
        dest_path  TEXT,
        PRIMARY KEY (session_id, image_id)
      ) WITHOUT ROWID
    ''');
  }

  /// v4 Run 历史表(createAll 全量建表用)。
  /// session_id 可空:单活跃会话模型下恒写 1,会话被新扫描覆写/清理后
  /// 日志行仅存摘要语义(计数 + errors),不悬挂关联查询。
  static Future<void> _createRunLogTable(sqflite.Database db) async {
    await db.execute('''
      CREATE TABLE run_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id  INTEGER,
        finished_at INTEGER NOT NULL,
        moved       INTEGER NOT NULL,
        deleted     INTEGER NOT NULL,
        skipped     INTEGER NOT NULL,
        errors      TEXT
      )
    ''');
  }
}
