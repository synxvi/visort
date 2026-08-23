# SQLite 改造路线图

> 2026-08 立项。目标:给"数据级"状态补上持久化层——目前项目只有配置级持久化
> (SharedPreferences / window_state.json),整理会话、相册快照等进程死亡即丢。
> 本文档是实施蓝图,按 P0→P4 分阶段推进,每阶段独立可验证、可交付。

## 1. 背景与边界

### 值得入库的数据(按价值排序)

| 数据 | 现状 | 痛点 | 阶段 |
|---|---|---|---|
| 整理会话(决策+索引+扫描结果) | 纯内存,进程死亡全丢 | 最大缺口——整理到一半被杀,决策蒸发 | P2 |
| 相册桶快照 | 整桶 JSON 塞 SharedPreferences 单字符串(`visort_snap_*`) | 大相册字符串巨大,全量读入+整体解析 | P1 |
| Run 结果 | Stream 事件看完即弃 | 无历史审计 | P3 |
| 桌面扫描 | 每次冷启动全量重扫 | 大目录慢 | P4 |

### 明确不入库的数据

- **收藏 / 回收站**:MediaStore `IS_FAVORITE` / `IS_TRASHED` 是 source of truth,本地只做乐观内存副本。
- **AppConfig**:SharedPreferences 单 JSON 足够小,留原地不迁。
- **窗口状态**:已有 `window_state.json`,不重做。

### 架构红线

- **两路数据不合并**(AGENTS.md §Filesystem abstraction):分类通路(SessionState)与相册通路(Gallery)各自建表,共享同一数据库文件。
- **MediaStore / 文件系统永远是 source of truth**:SQLite 只做快照、缓存、会话状态,可随时被重查覆盖,不做双向同步。
- **无 codegen 铁律**:手写 SQL + 手写 migration,不引入 drift/build_runner。

## 2. 选型

**sqflite ^2.x(安卓)+ sqflite_common_ffi ^2.x(Windows / 测试)**:

- 安卓生态标配,method channel 异步 API 不阻塞 UI;
- 桌面一行 `databaseFactory = databaseFactoryFfi` 切换;
- 纯 Dart 单测可用 ffi 内存库直接跑,与现有测试风格无缝;
- `path_provider` 已在依赖中。

## 3. 库与表设计

单库 `getApplicationSupportDirectory()/visort.db`,手写 `onCreate/onUpgrade`
版本迁移——每阶段升一版,练出真实迁移路径。

### P1(v1)相册通路

```sql
CREATE TABLE bucket_snapshot (
  bucket_id  TEXT PRIMARY KEY,
  sort_by    TEXT NOT NULL,
  asc        INTEGER NOT NULL,        -- 0/1
  next_cursor TEXT,                   -- keyset 分页游标
  updated_at INTEGER NOT NULL
);
CREATE TABLE bucket_photo (
  bucket_id TEXT NOT NULL,
  id        TEXT NOT NULL,            -- MediaStore _ID
  seq       INTEGER NOT NULL,         -- 列表序(恢复列表顺序)
  name TEXT, size INTEGER, mime TEXT,
  date_added_ms INTEGER, date_modified_ms INTEGER,
  is_favorite INTEGER, is_trashed INTEGER, date_trashed_ms INTEGER,
  width INTEGER, height INTEGER, is_hdr INTEGER,
  PRIMARY KEY (bucket_id, id)
) WITHOUT ROWID;
```

### v2(计划外插入)HDR 检测缓存

相册徽标提速:Kotlin 进程内 `hdrCache` 的落盘层,冷启动二次进桶零文件 IO,
跨桶/收藏/回收站视图共享。`hdr_cache(id PK, date_modified_ms, is_hdr)`,
mtime 校验同 Kotlin 语义;补测改 60 张/批渐进回填(首屏不等全桶长尾)。
后续阶段版本号顺延:P2→v3、P3→v4、P4→v5。

### P2(v3)分类通路

```sql
CREATE TABLE sort_session (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  source_dir TEXT NOT NULL,
  destination_parent TEXT NOT NULL,
  current_index INTEGER NOT NULL,
  folder_templates TEXT NOT NULL,     -- JSON(复用现有 codec)
  folders TEXT NOT NULL               -- JSON
);
CREATE TABLE sort_image (
  session_id INTEGER NOT NULL,
  image_id TEXT NOT NULL,             -- 桌面=相对路径,安卓=MediaStore _ID(跨重启稳定)
  seq INTEGER NOT NULL,
  root TEXT NOT NULL, relative_path TEXT NOT NULL,
  extension TEXT NOT NULL, display_name TEXT,
  PRIMARY KEY (session_id, image_id)
) WITHOUT ROWID;
CREATE TABLE sort_decision (
  session_id INTEGER NOT NULL,
  image_id TEXT NOT NULL,
  seq INTEGER NOT NULL,               -- 插入序;undo=删 max(seq),恢复按 seq 重建 LinkedHashMap
  action TEXT NOT NULL,               -- move / delete / skip
  dest_key TEXT, dest_label TEXT, dest_path TEXT,
  PRIMARY KEY (session_id, image_id)
) WITHOUT ROWID;
```

### P3(v4)

```sql
CREATE TABLE run_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER,                 -- 可空(session 清理后仅存摘要)
  finished_at INTEGER NOT NULL,
  moved INTEGER, deleted INTEGER, skipped INTEGER,
  errors TEXT                         -- JSON
);
```

### P4(v5,仅桌面)

```sql
CREATE TABLE scan_cache (
  root TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  mtime_ms INTEGER NOT NULL,
  size INTEGER NOT NULL,
  extension TEXT, display_name TEXT,
  PRIMARY KEY (root, relative_path)
) WITHOUT ROWID;
```

## 4. 分阶段路线

### P0 基础设施(半天)

- `sqflite` / `sqflite_common_ffi` 进 pubspec;
- `core/db/database_service.dart`:open + 版本迁移 + Riverpod provider;
- main.dart 启动注入(ProfilesService.load 同款模式,await 在 runApp 前);
- **降级红线**:所有方法 try-catch,任何 DB 故障 = 现状纯内存,永不崩 app。

### P1 桶快照迁移(半天)

- `core/db/gallery_snapshot_store.dart`(事务批量写,复用 `MsImageInfo` 现有 codec);
- `GalleryController._persistSnapshot/_loadDiskSnapshot` 换 store,语义完全对等
  (仍是首屏缓存,进 app 后 MediaStore + ContentObserver 照旧刷新);
- 旧 `visort_snap_*` 是缓存语义:直接废弃 + 一次性清 key,**不做数据搬迁**;
- 先做它的理由:纯替换现有功能、行为可对照验证,趟平 DB 基建。

### P2 会话持久化(一天,核心价值)

- `SessionController` 四个接入点:`initFromScan` / `decide` / `undo` / `reset`;
- 运行时内存 LinkedHashMap 仍是唯一真源,写库走 **400ms 防抖批量写**
  (与 home_screen_android 配置持久化同模式)+ 关键点强刷
  (进 review 屏、app 进后台 WidgetsBindingObserver paused 时 flush);
- 恢复 UX:启动检测到未完成会话 → Home 顶部"恢复上次整理"横条(非弹窗),
  新扫描覆盖旧会话;同时只保留一个活跃 session。

### P3 Run 历史(半天)

- `RunController.run` 结束写 run_log;UI 入口后议(默认只写表)。

### P4 桌面扫描缓存(半天,优先级最低)

- `DesktopFileSystem.scanImages` 按 (mtime, size) 增量;目录变更全量重建。

## 5. 测试策略

- Store 做成可注入接口:controller 现有测试注入 noop fake,行为零变化;
- Store 单测:`databaseFactory = databaseFactoryFfi` + 内存库(`:memory:`),
  纯 Dart 可跑,中文描述名,与现有 9 文件风格一致;
- 每阶段 `flutter analyze` 零新告警 + `flutter test` 全绿 + 真机对照验证。
