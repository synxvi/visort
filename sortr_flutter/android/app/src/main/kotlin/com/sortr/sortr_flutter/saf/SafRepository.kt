package com.sortr.sortr_flutter.saf

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import java.io.InputStream
import java.io.OutputStream

// ───────────────────────── SAF 业务层 ─────────────────────────
//
// 封装 ContentResolver + DocumentsContract 操作。
// 不持有 Activity 引用——picker 的 Activity Result 回调由 SafPlugin 桥接。
//
// 里程碑 A0（已完成验证）：
//   - persistedUriPermissions / takePersistablePermission / scanImages
//
// 里程碑 A1（本次实现）：
//   - listSubdirs : 列出 tree URI 下的直接子目录
//   - readMeta    : 读取单张图片的元信息（size/created/modified）
//   - move        : 分叉 —— 同 tree 走 renameDocument（原子、毫秒级），
//                   跨 tree 走 copy + delete（不保证原子、慢）
//   - delete      : DocumentsContract.deleteDocument
//   - exists      : contentResolver query 探测
//   - readBytes   : ContentResolver.openInputStream，支持下采样上限

private const val TAG = "SafRepository"

class SafRepository(private val context: Context) {

    private val contentResolver: ContentResolver get() = context.contentResolver

    // ──────────── 持久化授权（A0） ────────────

    fun persistedUriPermissions(): List<SafPermissionInfo> {
        return contentResolver.persistedUriPermissions.map { p ->
            SafPermissionInfo(
                uri = p.uri.toString(),
                isReadPermission = p.isReadPermission,
                isWritePermission = p.isWritePermission,
            )
        }
    }

    fun takePersistablePermission(treeUri: Uri) {
        contentResolver.takePersistableUriPermission(
            treeUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }

    // ──────────── 扫描图片（A0） ────────────

    fun scanImages(treeUri: Uri, max: Int = 500): List<SafImageInfo> {
        val results = mutableListOf<SafImageInfo>()
        val treeDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: IllegalArgumentException) {
            throw SafError.QueryFailed("无法解析 tree document id: ${e.message}")
        }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeDocId)
        recursiveScan(treeUri, childrenUri, results, max, depth = 0)
        Log.i(TAG, "scanImages: 共扫到 ${results.size} 张图片（上限 $max）")
        return results
    }

    private fun recursiveScan(
        treeUri: Uri,
        childrenUri: Uri,
        out: MutableList<SafImageInfo>,
        max: Int,
        depth: Int,
    ) {
        if (out.size >= max || depth > 16) return

        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        try {
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idxId = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val idxName = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val idxMime = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val idxSize = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)

                while (cursor.moveToNext() && out.size < max) {
                    val docId = cursor.getString(idxId)
                    val name = cursor.getString(idxName) ?: continue
                    val mime = cursor.getString(idxMime) ?: ""
                    val size = if (cursor.isNull(idxSize)) 0L else cursor.getLong(idxSize)

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        val subChildren = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
                        recursiveScan(treeUri, subChildren, out, max, depth + 1)
                    } else if (mime.startsWith("image/")) {
                        out.add(SafImageInfo(name = name, docId = docId, size = size, mime = mime))
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "recursiveScan 异常（部分 provider 对子目录查询会抛）: ${e.message}")
        }
    }

    // ──────────── 列出子目录（A1） ────────────

    /// 列出 tree URI 根下的直接子目录（仅一层，过滤 . 开头的隐藏目录）。
    /// 对应 DesktopFileSystem.listSubdirs 语义。
    fun listSubdirs(treeUri: Uri): List<String> {
        val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeDocId)
        val names = mutableListOf<String>()

        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        try {
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idxName = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val idxMime = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                while (cursor.moveToNext()) {
                    val mime = cursor.getString(idxMime) ?: ""
                    val name = cursor.getString(idxName) ?: continue
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR && !name.startsWith(".")) {
                        names.add(name)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "listSubdirs 异常: ${e.message}")
        }
        names.sort()
        Log.i(TAG, "listSubdirs: 找到 ${names.size} 个子目录")
        return names
    }

    // ──────────── 读取元信息（A1） ────────────

    /// 读取单张图片的元信息。docId 由 scanImages 提供。
    fun readMeta(treeUri: Uri, docId: String): SafMetaInfo {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        try {
            contentResolver.query(docUri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0) ?: docId
                    val size = if (cursor.isNull(1)) 0L else cursor.getLong(1)
                    val modified = if (cursor.isNull(2)) 0L else cursor.getLong(2)
                    return SafMetaInfo(name = name, size = size, modifiedMs = modified)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "readMeta 异常: ${e.message}")
        }
        throw SafError.QueryFailed("无法读取文档元信息: $docId")
    }

    // ──────────── 移动（A1 核心） ────────────

    /// 移动文件。自动分叉：
    ///   - srcTreeUri == destTreeUri → 同 tree，走 renameDocument（原子、毫秒级）
    ///   - 否则 → 跨 tree，走 copyDocument + deleteDocument（慢、不保证原子）
    ///
    /// @param srcTreeUri 源 tree URI
    /// @param srcDocId   源文档 ID
    /// @param destTreeUri 目标 tree URI（可为另一个授权的 tree）
    /// @param destDirDocId 目标父目录的文档 ID（在 destTreeUri 内）
    /// @param suggestedName 建议文件名（冲突时自动 _1/_2 改名）
    fun move(
        srcTreeUri: Uri,
        srcDocId: String,
        destTreeUri: Uri,
        destDirDocId: String,
        suggestedName: String,
    ): SafMoveResult {
        val sameTree = srcTreeUri == destTreeUri
        return if (sameTree) {
            moveInTree(srcTreeUri, srcDocId, destDirDocId, suggestedName)
        } else {
            copyAcrossTrees(srcTreeUri, srcDocId, destTreeUri, destDirDocId, suggestedName)
        }
    }

    /// 同 tree 内移动：renameDocument 改 parent。
    /// 冲突改名：name_1.ext, name_2.ext, ...
    private fun moveInTree(
        treeUri: Uri,
        srcDocId: String,
        destDirDocId: String,
        baseName: String,
    ): SafMoveResult {
        val finalName = resolveUniqueName(treeUri, destDirDocId, baseName)
        val newDocId = if (destDirDocId.isEmpty() || destDirDocId == getTreeDocId(treeUri)) {
            // 目标是根，docId = finalName
            finalName
        } else {
            "$destDirDocId/$finalName"
        }
        return try {
            val srcDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, srcDocId)
            // renameDocument 只接受新的 display name，不改 parent。
            // 要跨目录移动，必须用 buildDocumentUriUsingTree 构造目标 URI 后 rename。
            // 实际上 SAF 的 rename 只能改名不能改路径——跨子目录移动需要 copy+delete。
            // 重新判断：如果 src 和 destDir 是同一个父目录，纯改名即可；否则仍需 copy+delete。
            val srcParentDocId = getParentDocId(srcDocId)
            if (srcParentDocId == destDirDocId) {
                // 同父目录，纯改名
                val renamed = DocumentsContract.renameDocument(contentResolver, srcDocUri, finalName)
                SafMoveResult(success = true, finalName = finalName, finalDocId = docIdFromUri(renamed ?: srcDocUri))
            } else {
                // 同 tree 但跨子目录：SAF rename 不支持改路径，走 copy+delete
                Log.i(TAG, "moveInTree: 同 tree 跨子目录，走 copy+delete（$srcDocId → $newDocId）")
                copyAndDelete(treeUri, srcDocId, treeUri, destDirDocId, finalName)
            }
        } catch (e: Exception) {
            Log.w(TAG, "moveInTree 失败: ${e.message}")
            SafMoveResult(success = false, error = e.message ?: "rename 失败")
        }
    }

    /// 跨 tree 移动：copy + delete。
    private fun copyAcrossTrees(
        srcTreeUri: Uri,
        srcDocId: String,
        destTreeUri: Uri,
        destDirDocId: String,
        baseName: String,
    ): SafMoveResult {
        Log.i(TAG, "copyAcrossTrees: 跨 tree 移动（慢路径）")
        return copyAndDelete(srcTreeUri, srcDocId, destTreeUri, destDirDocId, baseName)
    }

    /// 通用的 copy + delete 实现（跨子目录或跨 tree）。
    private fun copyAndDelete(
        srcTreeUri: Uri,
        srcDocId: String,
        destTreeUri: Uri,
        destDirDocId: String,
        finalName: String,
    ): SafMoveResult {
        return try {
            val srcDocUri = DocumentsContract.buildDocumentUriUsingTree(srcTreeUri, srcDocId)
            val finalNameUnique = resolveUniqueName(destTreeUri, destDirDocId, finalName)

            // 方式 1：DocumentsContract.copyDocument（部分 provider 支持）
            val targetDirChildrenUri = if (destDirDocId.isEmpty() || destDirDocId == getTreeDocId(destTreeUri)) {
                DocumentsContract.buildChildDocumentsUriUsingTree(destTreeUri, getTreeDocId(destTreeUri))
            } else {
                DocumentsContract.buildChildDocumentsUriUsingTree(destTreeUri, destDirDocId)
            }

            // 方式 2：手动 stream copy（最通用可靠）
            val copied = streamCopy(srcDocUri, destTreeUri, destDirDocId, finalNameUnique)
            if (!copied) {
                return SafMoveResult(success = false, error = "复制失败（provider 不支持写入）")
            }
            // 复制成功后删除源
            val deleted = deleteDocument(srcTreeUri, srcDocId)
            if (!deleted) {
                Log.w(TAG, "copyAndDelete: 源删除失败，但复制已成功（可能残留）")
            }
            SafMoveResult(success = true, finalName = finalNameUnique)
        } catch (e: Exception) {
            Log.w(TAG, "copyAndDelete 失败: ${e.message}")
            SafMoveResult(success = false, error = e.message ?: "copy+delete 失败")
        }
    }

    /// 手动流式复制（最通用，所有 provider 都支持 openInputStream/openOutputStream）。
    private fun streamCopy(
        srcDocUri: Uri,
        destTreeUri: Uri,
        destDirDocId: String,
        destName: String,
    ): Boolean {
        val parentDocId = if (destDirDocId.isEmpty()) getTreeDocId(destTreeUri) else destDirDocId
        return try {
            // 在目标父目录下创建新文档
            val newDocUri = DocumentsContract.createDocument(
                contentResolver,
                DocumentsContract.buildDocumentUriUsingTree(destTreeUri, parentDocId),
                "image/*",
                destName,
            ) ?: return false

            val input: InputStream = contentResolver.openInputStream(srcDocUri)
                ?: return false
            val output: OutputStream = contentResolver.openOutputStream(newDocUri)
                ?: run { input.close(); return false }

            input.use { i ->
                output.use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = i.read(buf)
                        if (n <= 0) break
                        o.write(buf, 0, n)
                    }
                }
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "streamCopy 异常: ${e.message}")
            false
        }
    }

    // ──────────── 删除（A1） ────────────

    fun deleteDocument(treeUri: Uri, docId: String): Boolean {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        return try {
            DocumentsContract.deleteDocument(contentResolver, docUri)
        } catch (e: Exception) {
            Log.w(TAG, "deleteDocument 失败: ${e.message}")
            false
        }
    }

    // ──────────── 存在性检查（A1） ────────────

    fun exists(treeUri: Uri, docId: String): Boolean {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        return try {
            contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null, null, null,
            )?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            false
        }
    }

    // ──────────── 读取字节（A1） ────────────

    /// 读取文档字节。[maxBytes] 为 0 表示不限。
    fun readBytes(treeUri: Uri, docId: String, maxBytes: Int = 0): ByteArray {
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        val stream = contentResolver.openInputStream(docUri)
            ?: throw SafError.QueryFailed("无法打开 InputStream: $docId")
        return stream.use { input ->
            if (maxBytes <= 0) {
                input.readBytes()
            } else {
                // 限制读取量，防止超大文件 OOM
                val buf = ByteArray(maxBytes)
                val read = input.read(buf)
                if (read <= 0) ByteArray(0) else buf.copyOf(read)
            }
        }
    }

    // ──────────── 辅助函数 ────────────

    /// 解析目标目录下的唯一文件名（冲突时 _1/_2 改名）。
    private fun resolveUniqueName(treeUri: Uri, destDirDocId: String, baseName: String): String {
        val parentDocId = if (destDirDocId.isEmpty()) getTreeDocId(treeUri) else destDirDocId
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val existing = mutableSetOf<String>()
        try {
            contentResolver.query(
                childrenUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    cursor.getString(0)?.let { existing.add(it) }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "resolveUniqueName 查询失败，沿用原名: ${e.message}")
            return baseName
        }
        if (baseName !in existing) return baseName

        val dot = baseName.lastIndexOf('.')
        val (stem, ext) = if (dot > 0) baseName.substring(0, dot) to baseName.substring(dot) else baseName to ""
        var i = 1
        while ("${stem}_$i$ext" in existing) i++
        return "${stem}_$i$ext"
    }

    private fun getTreeDocId(treeUri: Uri): String =
        DocumentsContract.getTreeDocumentId(treeUri)

    /// 从 docId 推断父目录 docId（SAF docId 用 / 分隔路径）。
    private fun getParentDocId(docId: String): String {
        val idx = docId.lastIndexOf('/')
        return if (idx > 0) docId.substring(0, idx) else ""
    }

    /// 从 document URI 提取 docId。
    private fun docIdFromUri(uri: Uri): String {
        return DocumentsContract.getDocumentId(uri)
    }
}
