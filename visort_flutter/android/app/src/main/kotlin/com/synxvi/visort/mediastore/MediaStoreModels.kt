package com.synxvi.visort.mediastore

// ───────────────────────── MediaStore 数据模型 ─────────────────────────
//
// 与 Dart 侧 Map<String, Any> 对齐：
//   - MsBucket    → {id, name, count, dateCreatedMs, dateModifiedMs, coverId}
//   - MsImageInfo → {id, name, size, mime, bucketId, dateAddedMs, dateModifiedMs}
//   - MsMetaInfo  → {name, size, modifiedMs, width, height}

/// 一个相册（bucket）：id + 显示名 + 图片数 + 聚合日期 + 封面图 id。
///
/// 相册在 MediaStore 中非真实目录、无原生时间戳；下列日期由其内图片聚合：
///   - dateCreatedMs  = min(DATE_ADDED)  相册建立时间（最早一张入库）
///   - dateModifiedMs = max(DATE_MODIFIED) 相册最近变动时间
///
/// [coverId] 为该相册最新一张图片的 _ID（listBuckets 按 DATE_ADDED DESC 遍历，
/// 聚合时保留每个 bucket 游标首条即最新图）。null 表示无封面（查询失败或无图）。
data class MsBucket(
    val id: String,        // MediaStore Images.Media.BUCKET_ID
    val name: String,      // BUCKET_DISPLAY_NAME
    val count: Int,        // 该 bucket 下的图片总数
    val dateCreatedMs: Long,   // min(DATE_ADDED)*1000：相册建立时间
    val dateModifiedMs: Long,  // max(DATE_MODIFIED)*1000：相册最近变动时间
    val coverId: String? = null,  // 最新一张图的 _ID，用于首页封面缩略图
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "count" to count,
        "dateCreatedMs" to dateCreatedMs,
        "dateModifiedMs" to dateModifiedMs,
        "coverId" to coverId,
    )
}

/// 单张图片扫描结果
data class MsImageInfo(
    val id: String,             // MediaStore Images.Media._ID（ImageRef.relativePath 编码此值）
    val name: String,           // DISPLAY_NAME
    val size: Long,             // SIZE
    val mime: String,           // MIME_TYPE
    val bucketId: String,       // BUCKET_ID
    val dateAddedMs: Long,      // DATE_ADDED * 1000（创建/入库时间，秒→毫秒）
    val dateModifiedMs: Long,   // DATE_MODIFIED * 1000（修改时间，秒→毫秒）
    val isFavorite: Boolean = false,   // IS_FAVORITE（Android R+）；低版本始终 false
    val isTrashed: Boolean = false,   // IS_TRASHED（Android R+）；低版本始终 false
    val dateTrashedMs: Long = 0,   // DATE_EXPIRES * 1000（回收站删除日期；非回收站项为 0）
    val width: Int = 0,           // WIDTH 像素；损坏/未知项为 0，Dart 侧 fallback readMeta 取尺寸
    val height: Int = 0,          // HEIGHT 像素；损坏/未知项为 0
    val isHdr: Boolean = false,   // JPEG Ultra HDR（XMP hdrgm:Version gainmap，读文件头检测）；非 JPEG 恒 false
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "name" to name,
        "size" to size,
        "mime" to mime,
        "bucketId" to bucketId,
        "dateAddedMs" to dateAddedMs,
        "dateModifiedMs" to dateModifiedMs,
        "isFavorite" to isFavorite,
        "isTrashed" to isTrashed,
        "dateTrashedMs" to dateTrashedMs,
        "width" to width,
        "height" to height,
        "isHdr" to isHdr,
    )
}

/// 单图元信息（readMeta 返回）
data class MsMetaInfo(
    val name: String,
    val size: Long,
    val modifiedMs: Long,
    val width: Int,
    val height: Int,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "name" to name,
        "size" to size,
        "modifiedMs" to modifiedMs,
        "width" to width,
        "height" to height,
    )
}

/// 业务错误类型
sealed class MsError(val code: String, message: String) : Exception(message) {
    data class QueryFailed(override val message: String) : MsError("QUERY_FAILED", message)
    data class InvalidArg(override val message: String) : MsError("INVALID_ARG", message)
    object PermissionDenied : MsError("PERMISSION_DENIED", "READ_MEDIA_IMAGES 权限未授予")
    object DeleteCancelled : MsError("DELETE_CANCELLED", "用户取消删除")
    data class MetadataFailed(override val message: String) : MsError("METADATA_FAILED", message)
    object FavoriteUnsupported : MsError("FAVORITE_UNSUPPORTED", "收藏需要 Android 10+")
    object FavoriteCancelled : MsError("FAVORITE_CANCELLED", "用户取消收藏")
    object TrashUnsupported : MsError("TRASH_UNSUPPORTED", "回收站需要 Android 10+")
    object TrashCancelled : MsError("TRASH_CANCELLED", "用户取消移入回收站")
    object RestoreCancelled : MsError("RESTORE_CANCELLED", "用户取消恢复")
}
