package com.sortr.sortr_flutter.mediastore

// ───────────────────────── MediaStore 数据模型 ─────────────────────────
//
// 与 Dart 侧 Map<String, Any> 对齐：
//   - MsBucket    → {id, name, count, coverId}
//   - MsImageInfo → {id, name, size, mime, bucketId, dateAddedMs}
//   - MsMetaInfo  → {name, size, modifiedMs, width, height}

/// 一个相册（bucket）：id + 显示名 + 图片数 + 封面图 id
///
/// [coverId] 为该相册最新一张图片的 _ID（listBuckets 按 DATE_ADDED DESC 遍历，
/// 聚合时保留每个 bucket 游标首条即最新图）。null 表示无封面（查询失败或无图）。
data class MsBucket(
    val id: String,        // MediaStore Images.Media.BUCKET_ID
    val name: String,      // BUCKET_DISPLAY_NAME
    val count: Int,        // 该 bucket 下的图片总数
    val coverId: String? = null,  // 最新一张图的 _ID，用于首页封面缩略图
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "name" to name,
        "count" to count,
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
    val dateAddedMs: Long,      // DATE_ADDED * 1000（入库时间，秒→毫秒）
    val dateTakenMs: Long,      // DATE_TAKEN（拍摄时间，毫秒；为空回退 dateAddedMs）
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "name" to name,
        "size" to size,
        "mime" to mime,
        "bucketId" to bucketId,
        "dateAddedMs" to dateAddedMs,
        "dateTakenMs" to dateTakenMs,
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
}
