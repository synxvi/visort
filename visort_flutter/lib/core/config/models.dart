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
enum SortBy {
  name,
  dateCreated,
  dateModified,
  dateTrashed,
}

/// 分类模式（安卓端 Setup 选择）。
///   - toAlbum  : 移动到「已有相册」（改 RELATIVE_PATH 到目标 bucket）
///   - toNewDir : 在指定父目录下新建子目录归类（桌面端传统模式）
enum ClassifyMode {
  toAlbum,
  toNewDir,
}

/// 首页（Setup 源相册区）相册列表布局。
enum HomeLayout { list, grid }

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
    this.language = 'en',
    this.lastSourceDir = '',
    this.lastDestParent = '',
    this.albumSortBy = SortBy.name,
    this.albumSortAsc = true,
    this.photoSortBy = SortBy.dateCreated,
    this.photoSortAsc = false,
    this.homeLayout = HomeLayout.list,
    this.homeGridColumns = 3,
    this.photoGridColumns = 3,
  });

  /// 所有 Profile（name → Profile）。
  final Map<String, Profile> profiles;

  /// 当前激活的 Profile 名（key into [profiles]）。
  final String activeProfile;

  /// 语言代码：'en' | 'zh'。
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

  /// 首页（Setup 源相册区）布局：列表 / 网格。
  final HomeLayout homeLayout;

  /// 首页网格列数（3 或 4）。
  final int homeGridColumns;

  /// 相册内照片网格列数（2–5）。
  final int photoGridColumns;

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
        language: 'en',
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
    HomeLayout? homeLayout,
    int? homeGridColumns,
    int? photoGridColumns,
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
        homeLayout: homeLayout ?? this.homeLayout,
        homeGridColumns: homeGridColumns ?? this.homeGridColumns,
        photoGridColumns: photoGridColumns ?? this.photoGridColumns,
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
        'home_layout': homeLayout.name,
        'home_grid_columns': homeGridColumns,
        'photo_grid_columns': photoGridColumns,
        'profiles': {
          for (final e in profiles.entries) e.key: e.value.toJson(),
        },
      };

  /// 从 JSON 还原。
  ///
  /// 兼容两种历史格式：
  ///   - 新格式：profiles 为 Map<String, ProfileJson>
  ///   - 旧格式（裸列表）：profiles 为 List<{key,label}>，归入「Default」
  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final language = (json['language'] as String?) ?? 'en';
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
          (json['album_sort_asc'] ?? json['albumSortAsc'] as bool?) ?? true,
      photoSortBy: _parseSortBy(json['photo_sort_by'] ?? json['photoSortBy'],
          SortBy.dateCreated),
      photoSortAsc:
          (json['photo_sort_asc'] ?? json['photoSortAsc'] as bool?) ?? false,
      homeLayout: _parseHomeLayout(
          json['home_layout'] ?? json['homeLayout'], HomeLayout.list),
      homeGridColumns:
          (json['home_grid_columns'] ?? json['homeGridColumns'] as int?) ?? 3,
      photoGridColumns:
          (json['photo_grid_columns'] ?? json['photoGridColumns'] as int?) ??
              3,
    );
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
