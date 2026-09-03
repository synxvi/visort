// 应用配置数据模型 —— Profile / 文件夹模板 / 快捷键 / 排序偏好
//
// 本文件是「纯数据层」：定义不可变模型类、枚举、默认值与 JSON 编解码。
// 不定义 Riverpod provider（configProvider / profilesServiceProvider 见
// core/i18n/i18n.dart），也不定义持久化服务（ProfilesService 见
// core/config/profiles_service.dart）。
//
// 字段与 JSON 契约由 test/widget_test.dart 锁定，修改需同步更新测试。

import 'package:flutter/foundation.dart';

/// 排序维度（相册列表与相册内图片共用）。
///
/// `.name` 用于 MediaStore SQL 排序参数 + AppConfig JSON 序列化。
/// 安卓端数据映射：dateCreated→DATE_ADDED（入库即「创建到本机」，无真文件创建时间）、
/// dateModified→DATE_MODIFIED。拍摄时间(DATE_TAKEN)已移除。
/// dateTrashed→DATE_EXPIRES：仅回收站视图有意义（移入回收站时系统写入的过期时间，
/// 即「删除日期 + 30 天」）；其他视图由 [GalleryState.effectivePhotoSortBy] 回退到 dateCreated。
/// dateFavorited：非 MediaStore 列（系统无收藏时间戳）——收藏时刻由 app 本地
/// 记录（见 gallery_controller 收藏时间 SP），排序在 Dart 内存完成（全量拉取），
/// 仅收藏视图提供；SQL 查询回退 dateCreated。
enum SortBy {
  name,
  dateCreated,
  dateModified,
  dateTrashed,
  dateFavorited,
}

/// 分类模式（安卓端 Home 选择）。
///   - toAlbum  : 移动到「已有相册」（改 RELATIVE_PATH 到目标 bucket）
///   - toNewDir : 在指定父目录下新建子目录归类（桌面端传统模式）
enum ClassifyMode {
  toAlbum,
  toNewDir,
}

/// 首页（Home 源相册区）相册列表布局。
enum HomeLayout { list, grid }

/// 抽屉开合动画档位（仅安卓 Shell）：
/// - fast：开 250ms / 关 200ms——Material 2/3 官方规格的黄金值
///   （M2 Speed 明文 drawer opens 250ms / closes 200ms；M3 Standard 集
///   进屏 250 / 出屏 200 一致）。
/// - comfortable：开 320ms / 关 240ms——emphasized 方向约 +20%，节奏
///   更沉稳。两档都保持「关比开快」的非对称（退出不需要用户注意力）。
enum DrawerAnimSpeed { fast, comfortable }

/// 默认首页（仅安卓 Shell）：启动进入的一级页，也是其它一级页返回键的
/// 应用内终点（设置 → 通用 → 默认首页）。
enum DefaultHomePage { gallery, sort, favorites }

/// 文件夹模板：快捷键 + 显示名（不含路径）。
///
/// 路径在 [FolderDescriptor]（profiles_service.dart）里拼装。
@immutable
class FolderTemplate {
  const FolderTemplate({required this.key, required this.label});

  /// 快捷键（单个字符，大写），如 'A'、'S'。根目录用 [kRootDestKey]。
  final String key;

  /// 显示名 / 目录名，如 '风景'、'截图'。
  final String label;

  FolderTemplate copyWith({String? key, String? label}) =>
      FolderTemplate(key: key ?? this.key, label: label ?? this.label);

  Map<String, String> toJson() => {'key': key, 'label': label};

  factory FolderTemplate.fromJson(Map<String, dynamic> json) => FolderTemplate(
        key: ((json['key'] as String?) ?? '').toUpperCase(),
        label: (json['label'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderTemplate && key == other.key && label == other.label;

  @override
  int get hashCode => Object.hash(key, label);

  @override
  String toString() => 'FolderTemplate($key → $label)';
}

/// 操作快捷键：撤销 / 删除 / 跳过（均单字符，大写）。
@immutable
class ActionKeys {
  const ActionKeys({
    required this.undo,
    required this.delete,
    required this.skip,
  });

  final String undo;
  final String delete;
  final String skip;

  ActionKeys copyWith({String? undo, String? delete, String? skip}) =>
      ActionKeys(
        undo: undo ?? this.undo,
        delete: delete ?? this.delete,
        skip: skip ?? this.skip,
      );

  Map<String, String> toJson() => {
        'undo': undo,
        'delete': delete,
        'skip': skip,
      };

  factory ActionKeys.fromJson(Map<String, dynamic> json) => ActionKeys(
        undo: (json['undo'] as String?) ?? _default.undo,
        delete: (json['delete'] as String?) ?? _default.delete,
        skip: (json['skip'] as String?) ?? _default.skip,
      );

  static const _default = ActionKeys(undo: 'Z', delete: 'X', skip: 'C');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionKeys &&
          undo == other.undo &&
          delete == other.delete &&
          skip == other.skip;

  @override
  int get hashCode => Object.hash(undo, delete, skip);

  @override
  String toString() => 'ActionKeys(undo=$undo, delete=$delete, skip=$skip)';
}

/// 单个配置档案：文件夹模板 + 快捷键 + 分类模式 + 目标相册/父目录。
@immutable
class Profile {
  const Profile({
    required this.folders,
    required this.actionKeys,
    this.classifyMode = ClassifyMode.toNewDir,
    this.targetAlbumIds = const [],
    this.newDirParent,
  });

  /// 文件夹模板列表（键 + 名）。
  final List<FolderTemplate> folders;

  /// 操作快捷键。
  final ActionKeys actionKeys;

  /// 分类模式。
  final ClassifyMode classifyMode;

  /// toAlbum 模式下的目标相册 bucket id 列表。
  final List<String> targetAlbumIds;

  /// toNewDir 模式下的父目录（Windows=路径 / 安卓=tree URI）。可空。
  final String? newDirParent;

  // 区分 copyWith 的「未传 newDirParent」与「显式传 null（清空父目录）」。
  // 默认 `?? this.newDirParent` 会让 null 失效（fallback 回旧值），导致清空
  // 父目录后持久化的仍是旧值、重启又恢复旧值（而非 Visort 占位）。
  static const _newDirParentSentinel = Object();

  Profile copyWith({
    List<FolderTemplate>? folders,
    ActionKeys? actionKeys,
    ClassifyMode? classifyMode,
    List<String>? targetAlbumIds,
    Object? newDirParent = _newDirParentSentinel,
  }) =>
      Profile(
        folders: folders ?? this.folders,
        actionKeys: actionKeys ?? this.actionKeys,
        classifyMode: classifyMode ?? this.classifyMode,
        targetAlbumIds: targetAlbumIds ?? this.targetAlbumIds,
        newDirParent: identical(newDirParent, _newDirParentSentinel)
            ? this.newDirParent
            : newDirParent as String?,
      );

  Map<String, dynamic> toJson() => {
        'folders': folders.map((f) => f.toJson()).toList(),
        'actionKeys': actionKeys.toJson(),
        'classifyMode': classifyMode.name,
        'targetAlbumIds': targetAlbumIds,
        'newDirParent': newDirParent,
      };

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        folders: ((json['folders'] as List?) ?? const [])
            .map((f) => FolderTemplate.fromJson(f as Map<String, dynamic>))
            .toList(),
        actionKeys: json['actionKeys'] is Map
            ? ActionKeys.fromJson(json['actionKeys'] as Map<String, dynamic>)
            : const ActionKeys(undo: 'Z', delete: 'X', skip: 'C'),
        classifyMode: _parseClassifyMode(
            json['classifyMode'], ClassifyMode.toNewDir),
        targetAlbumIds:
            ((json['targetAlbumIds'] as List?) ?? const []).cast<String>(),
        newDirParent: json['newDirParent'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile &&
          listEquals(folders, other.folders) &&
          actionKeys == other.actionKeys &&
          classifyMode == other.classifyMode &&
          listEquals(targetAlbumIds, other.targetAlbumIds) &&
          newDirParent == other.newDirParent;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(folders),
        actionKeys,
        classifyMode,
        Object.hashAll(targetAlbumIds),
        newDirParent,
      );
}

ClassifyMode _parseClassifyMode(Object? value, ClassifyMode fallback) {
  if (value is String) {
    return ClassifyMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => fallback,
    );
  }
  return fallback;
}

/// 全局应用配置：多 Profile + 当前激活 Profile + 排序/路径偏好 + 语言。
///
/// 由 [ProfilesService] 持久化到 shared_preferences（JSON）。
/// 启动时 main() 读取后注入 [configProvider]（见 core/i18n/i18n.dart）。
@immutable
class AppConfig {
  const AppConfig({
    required this.profiles,
    required this.activeProfile,
    this.language = 'system',
    this.lastSourceDir = '',
    this.lastDestParent = '',
    this.albumSortBy = SortBy.name,
    this.albumSortAsc = true,
    this.photoSortBy = SortBy.dateCreated,
    this.photoSortAsc = false,
    // 收藏/回收站视图独立排序偏好（2026-09 用户定稿）：收藏默认按收藏
    // 日期降序、回收站默认按删除日期降序；与相册内（photoSortBy）互不影响。
    this.favSortBy = SortBy.dateFavorited,
    this.favSortAsc = false,
    this.trashSortBy = SortBy.dateTrashed,
    this.trashSortAsc = false,
    this.photoTimelineView = false,
    this.homeLayout = HomeLayout.grid,
    this.homeGridColumns = 3,
    this.photoGridColumns = 4,
    this.favoritesGridColumns = 4,
    this.trashGridColumns = 4,
    this.precacheEnabled = true,
    this.precacheQuotaMb = 512,
    this.mlIndexEnabled = true,
    this.mlFaceEnabled = false,
    this.drawerAnimSpeed = DrawerAnimSpeed.comfortable,
    this.defaultHomePage = DefaultHomePage.gallery,
    this.galleryLayout = HomeLayout.grid,
    this.galleryGridColumns = 3,
  });

  /// 所有 Profile（name → Profile）。
  final Map<String, Profile> profiles;

  /// 当前激活的 Profile 名（key into [profiles]）。
  final String activeProfile;

  /// 语言代码：'system'（跟随设备系统语言）| 'en' | 'zh'。
  final String language;

  /// 上次使用的源目录（Windows=路径 / 安卓=tree URI / 相册=bucket id）。
  final String lastSourceDir;

  /// 上次使用的目标父目录。
  final String lastDestParent;

  /// 相册列表排序偏好。
  final SortBy albumSortBy;
  final bool albumSortAsc;

  /// 相册内图片排序偏好。
  final SortBy photoSortBy;
  final bool photoSortAsc;

  /// 收藏视图排序偏好（独立于相册内）。dateFavorited 为本地记录的收藏
  /// 时间（MediaStore 无此列），仅收藏视图提供；默认收藏日期降序。
  final SortBy favSortBy;
  final bool favSortAsc;

  /// 回收站视图排序偏好（独立于相册内）。dateTrashed = DATE_EXPIRES
  /// （删除日期）；默认删除日期降序。
  final SortBy trashSortBy;
  final bool trashSortAsc;

  /// 相册内视图模式：false=沉浸网格(默认)；true=日期分组视图。
  final bool photoTimelineView;

  /// 首页（Home 源相册区）布局：列表 / 网格。
  final HomeLayout homeLayout;

  /// 首页网格列数（2–4，默认 3；选项面板步进调节）。
  final int homeGridColumns;

  /// 相册内照片网格列数（3–5；选项面板步进调节）。
  /// 收藏/回收站同属照片网格，列数独立记忆（见下方两个字段）。
  final int photoGridColumns;

  /// 收藏视图网格列数（3–5，独立于相册内）。
  final int favoritesGridColumns;

  /// 回收站视图网格列数（3–5，独立于相册内）。
  final int trashGridColumns;

  /// 空闲预缓存开关：交互静默 + 解码管线空闲时后台预生成全相册
  /// screenNail（full 档盘缓存），加快浏览。关闭时由设置页清空全量缓存。
  final bool precacheEnabled;

  /// 空闲预缓存磁盘配额（MB）。档位见设置页（256MB~2GB），默认 512MB。
  final int precacheQuotaMb;

  // ── 智能识别（搜索索引，设置页「智能识别」区开关）──
  // 总开关驱动后台全库 EXIF 扫描（拍摄时间/GPS/相机一次 pass），产物
  // SQLite search_index 表（与图片解码缓存分离，用户要求）；地点识别
  // 为分能力开关（坐标 → 国家/省/市名，系统 Geocoder）。
  // 人物识别已移除（本地人脸方案未采用）。

  /// 智能识别索引总开关：开启后后台扫描全部照片，一次 EXIF pass 提取
  /// 拍摄时间/GPS/相机建搜索索引（搜索页日期/地点/相机分类数据源）。
  final bool mlIndexEnabled;

  /// 人物识别开关：预留（需要人脸检测模型，当前版本未内置）。
  final bool mlFaceEnabled;

  /// 抽屉开合动画档位（舒适/快速），默认舒适（2026-09 用户定稿；
  /// 原 Material 黄金值快速）。
  final DrawerAnimSpeed drawerAnimSpeed;

  /// 默认首页：启动进入的一级页 + 其它一级页返回键的终点。
  final DefaultHomePage defaultHomePage;

  /// 首页（原「相册」页，返回终点）布局：列表 / 网格。与快速整理页的
  /// [homeLayout]/[homeGridColumns]（沿用历史字段名）完全解耦。
  final HomeLayout galleryLayout;

  /// 首页网格列数（2–4，默认 3；选项面板步进调节）。
  final int galleryGridColumns;

  /// 当前激活 Profile 的数据（便捷访问）。
  Profile get activeProfileData =>
      profiles[activeProfile] ?? profiles.values.first;

  /// 默认配置（首次启动用）：单 Profile「Default」。
  factory AppConfig.defaults() => const AppConfig(
        profiles: {
          'Default': Profile(
            folders: [],
            actionKeys: ActionKeys(undo: 'Z', delete: 'X', skip: 'C'),
          ),
        },
        activeProfile: 'Default',
        language: 'system',
      );

  AppConfig copyWith({
    Map<String, Profile>? profiles,
    String? activeProfile,
    String? language,
    String? lastSourceDir,
    String? lastDestParent,
    SortBy? albumSortBy,
    bool? albumSortAsc,
    SortBy? photoSortBy,
    bool? photoSortAsc,
    SortBy? favSortBy,
    bool? favSortAsc,
    SortBy? trashSortBy,
    bool? trashSortAsc,
    bool? photoTimelineView,
    HomeLayout? homeLayout,
    int? homeGridColumns,
    int? photoGridColumns,
    int? favoritesGridColumns,
    int? trashGridColumns,
    bool? precacheEnabled,
    int? precacheQuotaMb,
    bool? mlIndexEnabled,
    bool? mlFaceEnabled,
    DrawerAnimSpeed? drawerAnimSpeed,
    DefaultHomePage? defaultHomePage,
    HomeLayout? galleryLayout,
    int? galleryGridColumns,
  }) =>
      AppConfig(
        profiles: profiles ?? this.profiles,
        activeProfile: activeProfile ?? this.activeProfile,
        language: language ?? this.language,
        lastSourceDir: lastSourceDir ?? this.lastSourceDir,
        lastDestParent: lastDestParent ?? this.lastDestParent,
        albumSortBy: albumSortBy ?? this.albumSortBy,
        albumSortAsc: albumSortAsc ?? this.albumSortAsc,
        photoSortBy: photoSortBy ?? this.photoSortBy,
        photoSortAsc: photoSortAsc ?? this.photoSortAsc,
        favSortBy: favSortBy ?? this.favSortBy,
        favSortAsc: favSortAsc ?? this.favSortAsc,
        trashSortBy: trashSortBy ?? this.trashSortBy,
        trashSortAsc: trashSortAsc ?? this.trashSortAsc,
        photoTimelineView: photoTimelineView ?? this.photoTimelineView,
        homeLayout: homeLayout ?? this.homeLayout,
        homeGridColumns: homeGridColumns ?? this.homeGridColumns,
        photoGridColumns: photoGridColumns ?? this.photoGridColumns,
        favoritesGridColumns: favoritesGridColumns ?? this.favoritesGridColumns,
        trashGridColumns: trashGridColumns ?? this.trashGridColumns,
        precacheEnabled: precacheEnabled ?? this.precacheEnabled,
        precacheQuotaMb: precacheQuotaMb ?? this.precacheQuotaMb,
        mlIndexEnabled: mlIndexEnabled ?? this.mlIndexEnabled,
        mlFaceEnabled: mlFaceEnabled ?? this.mlFaceEnabled,
        drawerAnimSpeed: drawerAnimSpeed ?? this.drawerAnimSpeed,
        defaultHomePage: defaultHomePage ?? this.defaultHomePage,
        galleryLayout: galleryLayout ?? this.galleryLayout,
        galleryGridColumns: galleryGridColumns ?? this.galleryGridColumns,
      );

  /// 序列化为 JSON（可逆，见 [fromJson]）。
  Map<String, dynamic> toJson() => {
        'active_profile': activeProfile,
        'language': language,
        'last_source_dir': lastSourceDir,
        'last_dest_parent': lastDestParent,
        'album_sort_by': albumSortBy.name,
        'album_sort_asc': albumSortAsc,
        'photo_sort_by': photoSortBy.name,
        'photo_sort_asc': photoSortAsc,
        'fav_sort_by': favSortBy.name,
        'fav_sort_asc': favSortAsc,
        'trash_sort_by': trashSortBy.name,
        'trash_sort_asc': trashSortAsc,
        'photo_timeline_view': photoTimelineView,
        'home_layout': homeLayout.name,
        'home_grid_columns': homeGridColumns,
        'photo_grid_columns': photoGridColumns,
        'favorites_grid_columns': favoritesGridColumns,
        'trash_grid_columns': trashGridColumns,
        'precache_enabled': precacheEnabled,
        'precache_quota_mb': precacheQuotaMb,
        'ml_index_enabled': mlIndexEnabled,
        'ml_face_enabled': mlFaceEnabled,
        'drawer_anim_speed': drawerAnimSpeed.name,
        'default_home_page': defaultHomePage.name,
        'gallery_layout': galleryLayout.name,
        'gallery_grid_columns': galleryGridColumns,
        'profiles': {
          for (final e in profiles.entries) e.key: e.value.toJson(),
        },
      };

  /// 从 JSON 还原。
  ///
  /// 兼容两种历史格式：
  ///   - 新格式：profiles 为 `Map<String, ProfileJson>`
  ///   - 旧格式（裸列表）：profiles 为 `List<{key,label}>`，归入「Default」
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final language = (json['language'] as String?) ?? 'system';
    final lastSourceDir = (json['last_source_dir'] as String?) ??
        (json['lastSourceDir'] as String?) ??
        '';
    final lastDestParent = (json['last_dest_parent'] as String?) ??
        (json['lastDestParent'] as String?) ??
        '';

    final profiles = <String, Profile>{};
    final raw = json['profiles'];
    if (raw is Map) {
      raw.forEach((name, value) {
        profiles[name as String] =
            Profile.fromJson(value as Map<String, dynamic>);
      });
    } else if (raw is List) {
      // 旧格式：裸文件夹列表 → Default profile
      profiles['Default'] = Profile(
        folders: raw
            .map((f) => FolderTemplate.fromJson(f as Map<String, dynamic>))
            .toList(),
        actionKeys: const ActionKeys(undo: 'Z', delete: 'X', skip: 'C'),
      );
    }
    if (profiles.isEmpty) return AppConfig.defaults();

    final active = (json['active_profile'] as String?) ??
        (json['activeProfile'] as String?) ??
        profiles.keys.first;
    return AppConfig(
      profiles: profiles,
      activeProfile: profiles.containsKey(active) ? active : profiles.keys.first,
      language: language,
      lastSourceDir: lastSourceDir,
      lastDestParent: lastDestParent,
      albumSortBy: _parseSortBy(json['album_sort_by'] ?? json['albumSortBy'],
          SortBy.name),
      albumSortAsc:
          _jsonBool(json['album_sort_asc'], json['albumSortAsc'], true),
      photoSortBy: _parseSortBy(json['photo_sort_by'] ?? json['photoSortBy'],
          SortBy.dateCreated),
      photoSortAsc:
          _jsonBool(json['photo_sort_asc'], json['photoSortAsc'], false),
      // 缺 key（升级用户旧 JSON 不含）→ 与构造默认一致的视图专属默认。
      favSortBy: _parseSortBy(json['fav_sort_by'], SortBy.dateFavorited),
      favSortAsc: _jsonBool(json['fav_sort_asc'], null, false),
      trashSortBy: _parseSortBy(json['trash_sort_by'], SortBy.dateTrashed),
      trashSortAsc: _jsonBool(json['trash_sort_asc'], null, false),
      photoTimelineView: _jsonBool(json['photo_timeline_view'], null, false),
      homeLayout: _parseHomeLayout(
          json['home_layout'] ?? json['homeLayout'], HomeLayout.grid),
      homeGridColumns:
          _jsonInt(json['home_grid_columns'], json['homeGridColumns'], 3),
      photoGridColumns:
          _jsonInt(json['photo_grid_columns'], json['photoGridColumns'], 4),
      favoritesGridColumns: _jsonInt(json['favorites_grid_columns'], null, 4),
      trashGridColumns: _jsonInt(json['trash_grid_columns'], null, 4),
      precacheEnabled: _jsonBool(json['precache_enabled'], null, true),
      precacheQuotaMb: _jsonInt(json['precache_quota_mb'], null, 512),
      mlIndexEnabled: _jsonBool(json['ml_index_enabled'], null, true),
      mlFaceEnabled: _jsonBool(json['ml_face_enabled'], null, false),
      drawerAnimSpeed: _parseDrawerAnimSpeed(
          json['drawer_anim_speed'], DrawerAnimSpeed.comfortable),
      defaultHomePage: _parseDefaultHomePage(
          json['default_home_page'], DefaultHomePage.gallery),
      galleryLayout: _parseHomeLayout(
          json['gallery_layout'], HomeLayout.grid),
      galleryGridColumns: _jsonInt(json['gallery_grid_columns'], null, 3),
    );
  }
}

/// JSON 标量容错取值（2026-09 审查 F12）：SP JSON 手工编辑/旧格式下类型
/// 漂移（如 bool 存成 0/1）时，原 `a ?? b as bool?` / `as int?` 硬 cast
/// 形态的 `as` 对非 null 错类型直接抛 TypeError → 整个 fromJson 失败 →
/// 全部 profiles 回退默认（单标量损坏放大成全量丢配置）。此处按实际
/// 类型收敛，认不出的回退 [fallback]。
bool _jsonBool(Object? a, Object? b, bool fallback) => switch (a ?? b) {
      final bool v => v,
      final int v => v != 0,
      final String v => v == 'true' || v == '1',
      _ => fallback,
    };

int _jsonInt(Object? a, Object? b, int fallback) => switch (a ?? b) {
      final int v => v,
      final String v => int.tryParse(v) ?? fallback,
      _ => fallback,
    };

DrawerAnimSpeed _parseDrawerAnimSpeed(
    Object? value, DrawerAnimSpeed fallback) {
  switch (value) {
    case 'comfortable':
      return DrawerAnimSpeed.comfortable;
    case 'fast':
      return DrawerAnimSpeed.fast;
    default:
      return fallback;
  }
}

DefaultHomePage _parseDefaultHomePage(
    Object? value, DefaultHomePage fallback) {
  switch (value) {
    case 'gallery':
      return DefaultHomePage.gallery;
    case 'sort':
      return DefaultHomePage.sort;
    case 'favorites':
      return DefaultHomePage.favorites;
    default:
      return fallback;
  }
}

HomeLayout _parseHomeLayout(Object? value, HomeLayout fallback) {
  if (value is String) {
    switch (value) {
      case 'grid':
        return HomeLayout.grid;
      case 'list':
        return HomeLayout.list;
    }
  }
  return fallback;
}

SortBy _parseSortBy(Object? value, SortBy fallback) {
  if (value is String) {
    switch (value) {
      case 'name':
        return SortBy.name;
      case 'dateCreated':
        return SortBy.dateCreated;
      case 'dateModified':
        return SortBy.dateModified;
      case 'dateTrashed':
        return SortBy.dateTrashed;
      case 'dateFavorited':
        return SortBy.dateFavorited;
      // ── 旧版本枚举值迁移（v1：dateTaken/dateAdded → dateCreated）──
      // dateAdded 与 dateCreated 数据一致(均为 DATE_ADDED)；dateTaken(拍摄)无对应，
      // 归入 dateCreated 以保留「按时间排序」的偏好。
      case 'dateTaken':
      case 'dateAdded':
        return SortBy.dateCreated;
    }
  }
  return fallback;
}
