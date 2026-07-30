package com.sortr.sortr_flutter.mediastore

import android.app.RecoverableSecurityException
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.IntentSender
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import java.io.ByteArrayOutputStream
import java.io.InputStream

// ───────────────────────── MediaStore 业务层 ─────────────────────────
//
// 封装 MediaStore.Images.Media 查询 + 删除（Recovery API）。
//
// 核心方法：
//   - listBuckets()      : 按 BUCKET_ID 分组列出所有相册（名+数量）
//   - scanImages(ids)    : 按 bucket id 列表查询图片
//   - readMeta(id)       : 单图元信息
//   - readBytes(id, max) : 读字节流（图片加载用）
//   - createDeleteRequest(ids) : 构造批量删除 IntentSender（Android 10+ 系统弹窗）

private const val TAG = "MsRepository"

/// MediaStore Images 外部存储的 authority 常量。
/// Dart 侧 ImageRef.root 编码此值，ImageRef.relativePath 编码 _ID。
const val IMAGES_AUTHORITY = "content://media/external/images/media"

class MediaStoreRepository(private val context: Context) {

    private val contentResolver: ContentResolver get() = context.contentResolver

    /// 外部存储图片集合 URI
    private val collection: Uri
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

    // ──────────── 列出相册 ────────────

    /// 按 BUCKET_ID 分组列出所有含图片的相册。
    /// 对应系统相册 App 看到的相册列表。
    ///
    /// [sortBy] / [asc] 同时决定：
    ///   1. 每个相册的封面图（coverId）= 该相册在此排序下的第一张
    ///   2. 与 Dart 侧首页列表排序保持一致（列表顺序由 Dart 排，这里只管封面）
    ///
    /// coverId 策略：sortOrder 按指定维度排，游标遍历时每个 bucket 的首条
    /// 即为该排序下的第一张，聚合时保留其 _ID 作为 coverId。
    fun listBuckets(sortBy: String = "dateTaken", asc: Boolean = false): List<MsBucket> {
        val buckets = mutableListOf<MsBucket>()
        val projection = arrayOf(
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.DISPLAY_NAME,
        )
        // 构造 sortOrder：决定每个相册封面（首条）的排序基准
        val sortColumn = when (sortBy) {
            "name" -> MediaStore.Images.Media.DISPLAY_NAME
            "dateAdded" -> MediaStore.Images.Media.DATE_ADDED
            else -> MediaStore.Images.Media.DATE_TAKEN
        }
        val sortDir = if (asc) "ASC" else "DESC"
        try {
            contentResolver.query(
                collection, projection, null, null,
                "$sortColumn $sortDir"
            )?.use { cursor ->
                val idxId = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
                val idxName = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
                val idxCover = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                // 用 Map 聚合：bucketId → (name, count, coverId)
                // coverId 仅首次遇到时记录（游标按指定排序遍历，首条 = 该排序下第一张）
                data class Agg(val name: String, var count: Int, val coverId: String?)
                val agg = mutableMapOf<String, Agg>()
                while (cursor.moveToNext()) {
                    val bid = cursor.getString(idxId) ?: continue
                    val bname = cursor.getString(idxName) ?: "Unknown"
                    val coverId = cursor.getString(idxCover)
                    val cur = agg[bid]
                    if (cur == null) {
                        agg[bid] = Agg(bname, 1, coverId)
                    } else {
                        cur.count++
                    }
                }
                agg.forEach { (id, a) ->
                    buckets.add(MsBucket(id = id, name = a.name, count = a.count, coverId = a.coverId))
                }
                // 按数量降序（符合相册 App 习惯：大相册在前）
                buckets.sortByDescending { it.count }
            }
        } catch (e: Exception) {
            Log.w(TAG, "listBuckets 异常: ${e.message}")
        }
        Log.i(TAG, "listBuckets: 共 ${buckets.size} 个相册（sortBy=$sortBy, asc=$asc）")
        return buckets
    }

    // ──────────── 扫描图片 ────────────

    /// 按 bucket id 列表扫描图片，返回 List<MsImageInfo>。
    /// [bucketIds] 为空表示扫全部。
    /// [offset] 为跳过的条数（用于相册浏览分页：游标 moveToPosition 跳过前 offset 条）。
    fun scanImages(
        bucketIds: List<String>,
        max: Int = 2000,
        offset: Int = 0,
        sortBy: String = "dateTaken",
        asc: Boolean = false,
    ): List<MsImageInfo> {
        val results = mutableListOf<MsImageInfo>()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.DATE_TAKEN,
        )
        // selection：按 bucket id 过滤
        val (selection, args) = if (bucketIds.isEmpty()) {
            null to null
        } else {
            val placeholders = bucketIds.joinToString(",") { "?" }
            "${MediaStore.Images.Media.BUCKET_ID} IN ($placeholders)" to bucketIds.toTypedArray()
        }
        // 排序：跟随「相册内排序」(photoSortBy)，与 listBuckets 封面取首张的排序基准严格一致，
        // 保证首页封面 = 进相册看到的第一张。
        //   name → DISPLAY_NAME，dateAdded → DATE_ADDED，else → DATE_TAKEN
        val sortColumn = when (sortBy) {
            "name" -> MediaStore.Images.Media.DISPLAY_NAME
            "dateAdded" -> MediaStore.Images.Media.DATE_ADDED
            else -> MediaStore.Images.Media.DATE_TAKEN
        }
        val sortDir = if (asc) "ASC" else "DESC"
        val sortOrder = "$sortColumn $sortDir"

        try {
            contentResolver.query(collection, projection, selection, args, sortOrder)?.use { cursor ->
                val idxId = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val idxName = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val idxSize = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val idxMime = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                val idxBucket = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
                val idxDate = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val idxDateTaken = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)

                // 分页：跳过前 offset 条（moveToPosition 越界安全，返回 false）
                if (offset > 0 && !cursor.move(offset)) {
                    // offset 超出总数，无更多数据
                    return@use
                }
                while (cursor.moveToNext() && results.size < max) {
                    val id = cursor.getString(idxId) ?: continue
                    val name = cursor.getString(idxName) ?: continue
                    val size = if (cursor.isNull(idxSize)) 0L else cursor.getLong(idxSize)
                    val mime = cursor.getString(idxMime) ?: "image/*"
                    val bucketId = cursor.getString(idxBucket) ?: ""
                    val dateAdded = if (cursor.isNull(idxDate)) 0L else cursor.getLong(idxDate) * 1000
                    // DATE_TAKEN 为毫秒级（与 DATE_ADDED 的秒级不同）；为空时回退到入库日期
                    val dateTaken = if (cursor.isNull(idxDateTaken)) dateAdded
                    else cursor.getLong(idxDateTaken)
                    results.add(MsImageInfo(id, name, size, mime, bucketId, dateAdded, dateTaken))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "scanImages 异常: ${e.message}")
        }
        Log.i(TAG, "scanImages: 共 ${results.size} 张图片（offset=$offset, 上限 $max, sortBy=$sortBy, asc=$asc）")
        return results
    }

    // ──────────── 单图元信息 ────────────

    fun readMeta(id: String): MsMetaInfo {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLongOrNull() ?: -1L
        )
        val projection = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT,
        )
        try {
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0) ?: id
                    val size = if (cursor.isNull(1)) 0L else cursor.getLong(1)
                    val modified = if (cursor.isNull(2)) 0L else cursor.getLong(2) * 1000
                    val width = if (cursor.isNull(3)) 0 else cursor.getInt(3)
                    val height = if (cursor.isNull(4)) 0 else cursor.getInt(4)
                    return MsMetaInfo(name, size, modified, width, height)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "readMeta 异常: ${e.message}")
        }
        throw MsError.QueryFailed("无法读取图片元信息: $id")
    }

    // ──────────── 读取字节 ────────────

    fun readBytes(id: String, maxBytes: Int = 0): ByteArray {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLongOrNull() ?: -1L
        )
        val stream: InputStream = contentResolver.openInputStream(uri)
            ?: throw MsError.QueryFailed("无法打开 InputStream: $id")
        return stream.use { input ->
            if (maxBytes <= 0) {
                input.readBytes()
            } else {
                val buf = ByteArray(maxBytes)
                val read = input.read(buf)
                if (read <= 0) ByteArray(0) else buf.copyOf(read)
            }
        }
    }

    // ──────────── 读取缩略图（相册网格用） ────────────

    /// 读取单图缩略图字节（JPEG 编码）。
    ///
    /// API 29+ 用 ContentResolver.loadThumbnail（系统级高效，返回指定尺寸的 Bitmap）。
    /// API <29 不支持 loadThumbnail，返回空数组 —— Dart 侧检测到空回退 readBytes 全图下采样。
    ///
    /// [width]/[height] 为目标缩略图像素尺寸（如 256x256）。
    fun readThumbnail(id: String, width: Int = 256, height: Int = 256): ByteArray {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // 低版本不支持 loadThumbnail，返回空让 Dart 回退
            Log.d(TAG, "readThumbnail: API <29，跳过（id=$id）")
            return ByteArray(0)
        }
        val longId = id.toLongOrNull() ?: throw MsError.InvalidArg("非法图片 id: $id")
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        val bitmap: Bitmap = try {
            contentResolver.loadThumbnail(uri, Size(width, height), null)
        } catch (e: Exception) {
            throw MsError.QueryFailed("loadThumbnail 失败 id=$id: ${e.message}")
        }
        val baos = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, baos)
        return baos.toByteArray()
    }

    // ──────────── 批量删除（Recovery API） ────────────

    /// 构造批量删除的 IntentSender（Android 10+）。
    /// 返回 null 表示无需弹窗（老版本直接删除）或构造失败。
    /// 调用方（Plugin）用 startIntentSenderForResult 启动，系统会弹确认窗。
    fun createDeleteRequest(ids: List<String>): IntentSender? {
        if (ids.isEmpty()) return null
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        if (uris.isEmpty()) return null

        // MANAGE_MEDIA 已授权 → 尝试直接逐个删除（零弹窗）。
        // 注意：部分 ROM（如 ColorOS）即使 AppOps 报告 mode=ALLOWED，实际 contentResolver.delete
        // 仍会抛 "has no access" 异常。故删除失败的 URI 必须 fallback 到系统弹窗，否则会
        // 误报成功（return null → Dart 以为删了，实际文件还在）。
        if (hasManageMediaPermission()) {
            val failed = mutableListOf<Uri>()
            var deleted = 0
            for (uri in uris) {
                try {
                    contentResolver.delete(uri, null, null)
                    deleted++
                } catch (e: Exception) {
                    Log.w(TAG, "MANAGE_MEDIA 直接删除失败 $uri: ${e.message}")
                    failed.add(uri)
                }
            }
            Log.i(TAG, "createDeleteRequest (MANAGE_MEDIA): $deleted/${uris.size}, 失败=${failed.size}")
            // 全部删除成功 → 无需弹窗；否则对失败的 URI 走系统弹窗 fallback
            if (failed.isEmpty()) return null
            return systemDeleteRequest(failed)
        }

        return systemDeleteRequest(uris)
    }

    /// 构造系统级删除弹窗（Android 11+ 真删 / Android 10 回收站 / 9- 直接删）。
    /// 抽出以便 MANAGE_MEDIA 路径删除失败时复用 fallback。
    private fun systemDeleteRequest(uris: List<Uri>): IntentSender? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+：createDeleteRequest（批量，一次弹窗）
            Log.i(TAG, "systemDeleteRequest: Android R+ createDeleteRequest, uris=${uris.size}")
            MediaStore.createDeleteRequest(contentResolver, uris).intentSender
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10：createTrashRequest 放回收站（deleteRequest 在 11+ 才有）
            Log.i(TAG, "systemDeleteRequest: Android Q createTrashRequest(回收站), uris=${uris.size}")
            MediaStore.createTrashRequest(contentResolver, uris, true).intentSender
        } else {
            // Android 9 及以下：直接删（无弹窗）
            var deleted = 0
            for (uri in uris) {
                try {
                    contentResolver.delete(uri, null, null)
                    deleted++
                } catch (e: Exception) {
                    Log.w(TAG, "直接删除失败 $uri: ${e.message}")
                }
            }
            Log.i(TAG, "Android 9- 直接删除 $deleted/${uris.size}")
            null
        }
    }

    // ──────────── 存在性检查 ────────────

    fun exists(id: String): Boolean {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLongOrNull() ?: -1L
        )
        return try {
            contentResolver.query(
                uri, arrayOf(MediaStore.Images.Media._ID), null, null, null
            )?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            false
        }
    }

    // ──────────── 目标相册路径查询（模式二用） ────────────

    /// 查指定 bucket 的 RELATIVE_PATH（如 "Pictures/QQ"）。
    /// 用于模式二「移到已有相册」的目标路径解析。
    fun getBucketRelativePath(bucketId: String): String? {
        if (bucketId.isEmpty()) return null
        val projection = arrayOf(MediaStore.Images.Media.RELATIVE_PATH)
        val selection = "${MediaStore.Images.Media.BUCKET_ID} = ?"
        val args = arrayOf(bucketId)
        return try {
            contentResolver.query(collection, projection, selection, args, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
                    if (idx >= 0) cursor.getString(idx) else null
                } else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "getBucketRelativePath 异常: ${e.message}")
            null
        }
    }

    // ──────────── 批量移动（改 RELATIVE_PATH） ────────────

    /// 构造批量改 RELATIVE_PATH 的请求。
    /// 流程：
    ///   - 若有 MANAGE_MEDIA 权限 → 直接逐个 update（零弹窗）
    ///   - 否则先尝试 update（自有文件成功），失败则返回 createWriteRequest 弹窗
    ///
    /// [relativePath] 如 "Pictures/QQ" 或 "Pictures/整理结果/保留"
    /// 返回 IntentSender（调用方启动弹窗），null 表示已直接完成或无需弹窗
    /// 移动结果：要么直接完成（返回成功数），要么需要弹窗（返回 IntentSender）
    sealed class MoveResult {
        data class Done(val successCount: Int) : MoveResult()
        data class NeedsConsent(val intentSender: IntentSender) : MoveResult()
    }

    fun moveToRelativePath(ids: List<String>, relativePath: String): MoveResult {
        if (ids.isEmpty() || relativePath.isEmpty()) return MoveResult.Done(0)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.w(TAG, "Android 9- 不支持 RELATIVE_PATH，跳过移动")
            return MoveResult.Done(0)
        }

        // 先尝试直接逐个 update（自有文件直接成功，无需授权）
        val success = doMoveToRelativePath(ids, relativePath)
        if (success == ids.size) {
            Log.i(TAG, "moveToRelativePath 全部直接成功: $success/${ids.size} → $relativePath")
            return MoveResult.Done(success)
        }

        // 部分或全部失败（其他 app 的文件需授权）
        val remaining = ids.size - success
        Log.i(TAG, "moveToRelativePath 部分失败 $success/${ids.size}（$remaining 张需授权）")

        // MANAGE_MEDIA 已授权 → createWriteRequest 免弹窗直接通过，授权后重新 doMove
        if (hasManageMediaPermission() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val uris = ids.mapNotNull { id ->
                val longId = id.toLongOrNull() ?: return@mapNotNull null
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
            }
            return try {
                // createWriteRequest 在 MANAGE_MEDIA 授权下不弹窗，返回的 PendingIntent 直接启动
                val intentSender = MediaStore.createWriteRequest(contentResolver, uris).intentSender
                MoveResult.NeedsConsent(intentSender)
            } catch (e: Exception) {
                Log.w(TAG, "moveToRelativePath createWriteRequest 异常: ${e.message}")
                MoveResult.Done(success)
            }
        }

        // 无 MANAGE_MEDIA → createWriteRequest 会弹窗
        return try {
            val sender = buildWriteRequest(ids)
            if (sender != null) MoveResult.NeedsConsent(sender) else MoveResult.Done(success)
        } catch (e: Exception) {
            Log.w(TAG, "moveToRelativePath buildWriteRequest 异常: ${e.message}")
            MoveResult.Done(success)
        }
    }

    /// 检查是否有 MANAGE_MEDIA 特殊权限（Android 12+，授权后媒体操作零弹窗）
    ///
    /// 重要：MANAGE_MEDIA 是 appop 级别权限，checkSelfPermission 检测不准（即使授权也返回 DENIED）。
    /// 必须用 AppOpsManager 检测 OPSTR_MANAGE_MEDIA 的 mode。
    fun hasManageMediaPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val appOps = context.getSystemService(android.content.Context.APP_OPS_SERVICE)
            as? android.app.AppOpsManager ?: return false
        // MANAGE_MEDIA 的 appop 字符串是 "android:manage_media"（公共常量未暴露，直接用字符串）
        val opStr = "android:manage_media"
        val mode = try {
            appOps.unsafeCheckOpNoThrow(opStr, android.os.Process.myUid(), context.packageName)
        } catch (e: Exception) {
            Log.w(TAG, "hasManageMediaPermission AppOps 检测异常: ${e.message}")
            return false
        }
        val granted = mode == android.app.AppOpsManager.MODE_ALLOWED
        Log.i(TAG, "hasManageMediaPermission: $granted (mode=$mode, SDK=${Build.VERSION.SDK_INT})")
        return granted
    }

    /// 真正执行 RELATIVE_PATH update。返回成功更新的行数。
    /// 授权通过后必须调用此方法才能真移动。
    ///
    /// 重要：Android 10+ 不允许对 EXTERNAL_CONTENT_URI（集合）批量 update，
    /// 必须对每个图片的单独 content URI（content://media/external/images/media/<id>）逐个 update。
    fun doMoveToRelativePath(ids: List<String>, relativePath: String): Int {
        if (ids.isEmpty() || relativePath.isEmpty()) return 0
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0

        val normalizedPath = if (relativePath.endsWith("/")) relativePath else "$relativePath/"
        var success = 0
        for (id in ids) {
            val longId = id.toLongOrNull() ?: continue
            // 逐个 URI update（不能用集合 URI + IN 子句）
            val itemUri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
            )
            try {
                val cv = android.content.ContentValues().apply {
                    put(MediaStore.Images.Media.RELATIVE_PATH, normalizedPath)
                }
                val rows = contentResolver.update(itemUri, cv, null, null)
                if (rows > 0) success++
                Log.i(TAG, "doMoveToRelativePath item $id: $rows 行 → $normalizedPath")
            } catch (e: Exception) {
                Log.w(TAG, "doMoveToRelativePath item $id 异常: ${e.message}")
            }
        }
        Log.i(TAG, "doMoveToRelativePath 完成: $success/${ids.size} → $normalizedPath")
        return success
    }

    /// 构造授权请求的 IntentSender。
    /// 策略：尝试 update（用真实 RELATIVE_PATH），捕获 SecurityException 获取授权 intentSender。
    /// 授权通过后，Plugin 会重新调 doMoveToRelativePath 执行移动。
    @Throws(Exception::class)
    private fun buildWriteRequest(ids: List<String>): IntentSender? {
        // 先构造 URI 列表
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        if (uris.isEmpty()) return null

        // Android 11+：直接用 createWriteRequest 获取批量写权限（最可靠）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return MediaStore.createWriteRequest(contentResolver, uris).intentSender
        }

        // Android 10：尝试 update 触发 RecoverableSecurityException（无 createWriteRequest）
        // 用空 values + 选中项 selection 来触发权限检查
        return try {
            val cv = android.content.ContentValues() // 空 values，update 只触发权限检查不实际修改
            contentResolver.update(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv,
                "${MediaStore.Images.Media._ID} IN (${ids.joinToString(",")})", null
            )
            null
            contentResolver.update(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv,
                "${MediaStore.Images.Media._ID} IN (${ids.joinToString(",")})", null
            )
            null
        } catch (e: RecoverableSecurityException) {
            e.userAction.actionIntent.intentSender
        }
    }
}
