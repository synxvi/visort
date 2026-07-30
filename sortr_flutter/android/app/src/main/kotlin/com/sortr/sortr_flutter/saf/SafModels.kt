package com.sortr.sortr_flutter.saf

// ───────────────────────── SAF 数据模型 ─────────────────────────
//
// 与 Dart 侧 Map<String, Any> 对齐：
//   - SafImageInfo        → {name, docId, size, mime}
//   - SafPermissionInfo   → {uri, isReadPermission, isWritePermission}
//
// 里程碑 A0：仅 pickDirectory / scanImages / persistedUriPermissions 使用。
// 里程碑 A1 将扩展 move/delete/readBytes 的模型。

/// 单张图片的扫描结果。
data class SafImageInfo(
    val name: String,    // 显示名（含扩展名）
    val docId: String,   // DocumentsContract 文档 ID（跨操作复用）
    val size: Long,      // 字节数
    val mime: String,    // MIME 类型（image/jpeg 等）
) {
    /// 序列化为 MethodChannel 可传的 Map
    fun toMap(): Map<String, Any> = mapOf(
        "name" to name,
        "docId" to docId,
        "size" to size,
        "mime" to mime,
    )
}

/// 单条持久化授权记录。
data class SafPermissionInfo(
    val uri: String,
    val isReadPermission: Boolean,
    val isWritePermission: Boolean,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "uri" to uri,
        "isReadPermission" to isReadPermission,
        "isWritePermission" to isWritePermission,
    )
}

/// 文档元信息（A1 readMeta 返回）。与 Dart ImageMeta 对齐。
data class SafMetaInfo(
    val name: String,
    val size: Long,        // 字节数
    val modifiedMs: Long,  // 最后修改时间（Unix 毫秒）
) {
    fun toMap(): Map<String, Any> = mapOf(
        "name" to name,
        "size" to size,
        "modifiedMs" to modifiedMs,
    )
}

/// 移动操作结果（A1 move 返回）。与 Dart MoveResult 对齐。
data class SafMoveResult(
    val success: Boolean,
    val finalName: String? = null,
    val finalDocId: String? = null,
    val error: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "success" to success,
        "finalName" to finalName,
        "finalDocId" to finalDocId,
        "error" to error,
    )
}

/// 业务错误类型，转成 Map 后通过 channel result.error 的 code 传给 Dart
sealed class SafError(val code: String, message: String) : Exception(message) {
    object Cancelled : SafError("CANCELLED", "用户取消选择")
    object NoUri : SafError("NO_URI", "未返回 tree URI")
    data class QueryFailed(override val message: String) : SafError("QUERY_FAILED", message)
    data class InvalidArg(override val message: String) : SafError("INVALID_ARG", message)
}
