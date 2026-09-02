// SQLite 底座(P0)—— 数据级持久化的 open
//
// 设计要点(见 docs/SQLITE_ROADMAP.md §4 P0):
//   - 安卓: sqflite 默认 method-channel factory(系统 SQLite);
//     Windows: databaseFactory = databaseFactoryFfi(原生库由 sqlite3_flutter_libs 捆绑)。
//   - 降级红线: open 全程 try-catch,失败保持 _db = null——所有 store
//     拿到 null 后 noop,app 行为回到无持久化现状,永不因 DB 故障崩溃。
//   - 时序: main() 以 unawaited 预热 init();store 一律经 [database] getter
//     (幂等,未初始化会自行 await init),与预热双保险,无竞态。
//   - 版本策略(2026-08 简化, 2026-09 修订): schema 变更直接改 [createAll]
//     全量 DDL 并升 kDbVersion;升版库走 onUpgrade 重放全表 IF NOT EXISTS
//     DDL(幂等,只补缺失表不动旧数据),列级变更仍用 ALTER+try-catch;
//     高版本老库降级由 sqflite 默认 onDowngrade(删库重建)兜底。
//     (历史教训: v5 曾把新列写进 _createSortTables 又在 onUpgrade 里
//     ALTER 同名列, v1/v2 库升级必炸 duplicate column——故 DDL 与 ALTER
//     职责分离,ALTER 只做加列且容忍 duplicate。)

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据库版本。无存量用户策略(见文件头):schema 变更时直接升此号并
/// 改 createAll 全量 DDL,不写迁移——高版本老库降级由 sqflite 默认
/// onDowngrade(删库重建)处理。
const int kDbVersion = 3;

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
          // 增量升级(仅加表不动旧数据):「无迁移、删库重建」策略对已装
          // 真机会连 sort_session 等一并清掉;此处只补建缺失表,与
          // createAll 共用每版 DDL(v1→v2 起适用)。
          onUpgrade: _onUpgrade,
        ),
      );
      // 幂等清理：v3 曾建的 idx_search_place/camera 两个复合索引——查询
      // 模式只有 loadAll 全表扫 / upsert / 主键 IN 删除，全不走它们，
      // 纯写放大（审查 P2）。DDL 已不再创建；每次 open 幂等 DROP 兜住
      // 已升级过的库（onUpgrade 对同版本库不触发）。
      try {
        await _db!.execute('DROP INDEX IF EXISTS idx_search_place');
        await _db!.execute('DROP INDEX IF EXISTS idx_search_camera');
      } catch (_) {}
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

  /// 升级补建(onUpgrade)：对全部表重放 createAll 的 IF NOT EXISTS DDL——
  /// 幂等，缺失表补齐、已有表（含旧 schema）原样不动。
  ///
  /// (2026-09 审查 F9) 原逐版补建只覆盖 search_index：v1/v2 装机
  /// （onUpgrade 尚未存在或只建 search_index 的年代）直升当前版后
  /// sort_session/hdr_cache/run_log 等表缺失，被 store 裸 catch(_) 吞成
  /// 「会话持久化/Run 历史静默失效」。全表重放一并兜住。
  static Future<void> _onUpgrade(
      sqflite.Database db, int oldVersion, int newVersion) async {
    await createAll(db);
    if (oldVersion < 3) {
      // v3: 索引行加提取时的 DATE_MODIFIED——增量对账据它检测「照片
      // 被外部编辑(EXIF 变更)后重提取」。ALTER 无 IF NOT EXISTS；列已
      // 存在（上一步 createSearchIndexTable 新建即含此列）时 duplicate
      // column 意外由 try-catch 吞掉(历史教训)。
      try {
        await db.execute(
            'ALTER TABLE search_index ADD COLUMN date_modified_ms INTEGER');
      } catch (_) {}
    }
  }


  /// 建当前版本的全部表(测试的内存库复用同一 schema,保证不漂移)。
  /// 升版时此方法更新为「最新全量」并升 kDbVersion,无迁移路径。
  static Future<void> createAll(sqflite.Database db) async {
    // ── v1 (P1): 相册桶快照 ──
    // snapshot 行携带分页游标与排序(快照总是某排序下的列表前缀);
    // photo 行复用 MsImageInfo 字段,seq 保列表序(恢复顺序)。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bucket_snapshot (
        bucket_id   TEXT PRIMARY KEY,
        sort_by     TEXT NOT NULL,
        asc         INTEGER NOT NULL,
        next_cursor TEXT,
        updated_at  INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bucket_photo (
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
      CREATE TABLE IF NOT EXISTS hdr_cache (
        id               TEXT PRIMARY KEY,
        date_modified_ms INTEGER NOT NULL,
        is_hdr           INTEGER NOT NULL
      ) WITHOUT ROWID
    ''');
    // ── v3 (P2): 整理会话 ──
    await _createSortTables(db);
    // ── v4 (P3): Run 历史 ──
    await _createRunLogTable(db);
    // ── v5 (搜索 v2): 搜索索引（智能识别索引产物）──
    await createSearchIndexTable(db);
  }

  /// v2 新增:搜索索引表(全量建表与 onUpgrade 补建共用)。
  ///
  /// 每行一张图的 EXIF 派生数据（拍摄时间/GPS/相机/地名）。MediaStore
  /// 无 DATE_TAKEN 与 GPS 列，此表是搜索页日期/地点/相机维度的唯一数据源。
  /// 地名列冗余存（同坐标照片重复同值），换查询免 join；id 对齐
  /// MediaStore _ID，照片本体仍以 MediaStore 为准——本表只是富化缓存。
  static Future<void> createSearchIndexTable(sqflite.Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_index (
        id            TEXT PRIMARY KEY,
        date_taken_ms INTEGER,
        lat           REAL,
        lng           REAL,
        camera        TEXT,
        country       TEXT,
        admin_area    TEXT,
        locality      TEXT,
        date_modified_ms INTEGER
      ) WITHOUT ROWID
    ''');
    // 不建二级索引：查询模式是 loadAll 全表/upsert/主键 IN 删除，
    // 复合索引只带来写放大（2026-09 审查）。
  }

  /// v3 会话三表(createAll 全量建表用,保证 schema 一致)。
  ///
  /// session 行 id 恒为 1(单活跃会话:新扫描整体覆写旧的);image_id 桌面=
  /// 相对路径、安卓=MediaStore _ID(跨重启稳定);decision.seq 为决策插入序
  /// (恢复时按 seq 重建 LinkedHashMap,undo 弹末位)。
  static Future<void> _createSortTables(sqflite.Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sort_session (
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
      CREATE TABLE IF NOT EXISTS sort_image (
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
      CREATE TABLE IF NOT EXISTS sort_decision (
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
      CREATE TABLE IF NOT EXISTS run_log (
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
