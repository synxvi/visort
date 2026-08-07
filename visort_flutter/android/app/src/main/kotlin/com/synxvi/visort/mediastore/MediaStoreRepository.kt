package com.synxvi.visort.mediastore

import android.app.RecoverableSecurityException
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.IntentSender
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.concurrent.Semaphore
import kotlin.math.max

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
    fun listBuckets(sortBy: String = "dateCreated", asc: Boolean = false): List<MsBucket> {
        val buckets = mutableListOf<MsBucket>()
        val projection = arrayOf(
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.IS_TRASHED,
        )
        // 构造 sortOrder：决定每个相册封面（首条）的排序基准
        val sortColumn = when (sortBy) {
            "name" -> MediaStore.Images.Media.DISPLAY_NAME
            "dateModified" -> MediaStore.Images.Media.DATE_MODIFIED
            else -> MediaStore.Images.Media.DATE_ADDED   // dateCreated 及未知值
        }
        val sortDir = if (asc) "ASC" else "DESC"
        try {
            // 与 scanImages 一致：R+ 用 Bundle query 显式排除回收站项。
            // 旧式 selection 参数在 ColorOS 上对 MANAGE_MEDIA 应用不生效
            // （默认查询含回收站项，导致删除后首页 count/封面不更新）。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bundle = android.os.Bundle().apply {
                    putString(
                        android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,
                        "${MediaStore.Images.Media.IS_TRASHED} = 0"
                    )
                    putString(
                        android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                        "$sortColumn $sortDir"
                    )
                    // MANAGE_MEDIA app 默认查询含回收站项（MATCH_INCLUDE）——
                    // 必须显式 MATCH_EXCLUDE 才可靠（与回收站视图 MATCH_INCLUDE 对称）。
                    putInt(
                        MediaStore.QUERY_ARG_MATCH_TRASHED,
                        MediaStore.MATCH_EXCLUDE
                    )
                }
                contentResolver.query(collection, projection, bundle, null)?.use { cursor ->
                    aggregateBuckets(cursor, buckets)
                }
            } else {
                contentResolver.query(
                    collection, projection, null, null,
                    "$sortColumn $sortDir"
                )?.use { cursor ->
                    aggregateBuckets(cursor, buckets)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "listBuckets 异常: ${e.message}")
        }
        Log.i(TAG, "listBuckets: 共 ${buckets.size} 个相册（sortBy=$sortBy, asc=$asc）")
        return buckets
    }

    /** listBuckets 游标聚合（按 BUCKET_ID 分组：name/count/coverId/创建/修改时间）。 */
    private fun aggregateBuckets(cursor: android.database.Cursor, buckets: MutableList<MsBucket>) {
        val idxId = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
        val idxName = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
        val idxCover = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
        val idxDateAdded = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
        val idxDateModified = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
        // ColorOS 的 MATCH_TRASHED/selection 对 MANAGE_MEDIA app 不可靠，
        // 代码级手动跳过回收站行（R+），保证 count/coverId 永远不含回收站项。
        val idxTrash = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
            cursor.getColumnIndex(MediaStore.Images.Media.IS_TRASHED) else -1
        data class Agg(
            val name: String, var count: Int, val coverId: String?,
            var minDateAdded: Long = Long.MAX_VALUE, var maxDateModified: Long = 0L,
        )
        val agg = mutableMapOf<String, Agg>()
        while (cursor.moveToNext()) {
            if (idxTrash >= 0 && cursor.getInt(idxTrash) == 1) continue
            val bid = cursor.getString(idxId) ?: continue
            val bname = cursor.getString(idxName) ?: "根目录"
            val coverId = cursor.getString(idxCover)
            val dateAdded = if (cursor.isNull(idxDateAdded)) 0L else cursor.getLong(idxDateAdded) * 1000
            val dateModified = if (cursor.isNull(idxDateModified)) 0L else cursor.getLong(idxDateModified) * 1000
            val cur = agg.getOrPut(bid) { Agg(bname, 0, coverId) }
            cur.count++
            if (dateAdded > 0 && dateAdded < cur.minDateAdded) cur.minDateAdded = dateAdded
            if (dateModified > cur.maxDateModified) cur.maxDateModified = dateModified
        }
        agg.forEach { (id, a) ->
            buckets.add(MsBucket(
                id = id, name = a.name, count = a.count,
                dateCreatedMs = if (a.minDateAdded == Long.MAX_VALUE) 0L else a.minDateAdded,
                dateModifiedMs = a.maxDateModified,
                coverId = a.coverId,
            ))
        }
        // 按数量降序（符合相册 App 习惯：大相册在前）
        buckets.sortByDescending { it.count }
    }

    // ──────────── 扫描图片（keyset 分页） ────────────

    /// 按 bucket id 列表扫描一页图片（keyset 游标分页）。
    ///
    /// keyset 分页用「上一页最后一条的 (排序值, _ID)」作为下一页的 WHERE 起点，
    /// 天然免疫条目增删导致的偏移（offset 分页在删除后会重复/跳过）。
    ///
    /// 排序恒为复合 `(sortColumn, _ID)`，保证同排序值内顺序稳定。
    ///
    /// @param bucketIds 为空表示扫全部
    /// @param afterCursor 上一页返回的 nextCursor（"sortValue|id"），null = 第一页
    /// @param limit 本页上限（默认 60）
    /// @return [ScanPage]：本页图片 + 下一页游标（null = 无更多）
    fun scanImages(
        bucketIds: List<String>,
        afterCursor: String? = null,
        limit: Int = 60,
        sortBy: String = "dateCreated",
        asc: Boolean = false,
        favoritesOnly: Boolean = false,
        trashedOnly: Boolean = false,
    ): ScanPage {
        val results = mutableListOf<MsImageInfo>()
        // 多查一列 _ID 用作 keyset 二级排序键；sortColumn 用于游标比较
        val projection = ArrayList<String>().apply {
            add(MediaStore.Images.Media._ID)
            add(MediaStore.Images.Media.DISPLAY_NAME)
            add(MediaStore.Images.Media.SIZE)
            add(MediaStore.Images.Media.MIME_TYPE)
            add(MediaStore.Images.Media.BUCKET_ID)
            add(MediaStore.Images.Media.DATE_ADDED)
            add(MediaStore.Images.Media.DATE_MODIFIED)
            // 原图像素尺寸（viewer 双击自适应铺满按宽高比算 coverRatio；损坏项为 0）
            add(MediaStore.Images.Media.WIDTH)
            add(MediaStore.Images.Media.HEIGHT)
            // IS_FAVORITE 仅 Android R+ 存在；低版本不加该列，解析时 getColumnIndex 返回 -1 当 false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                add(MediaStore.Images.Media.IS_FAVORITE)
                add(MediaStore.Images.Media.IS_TRASHED)
                // DATE_EXPIRES：回收站项的过期时间（移入回收站时刻 + 30 天），
                // 作「删除日期」排序键。仅 R+ 且仅回收站视图使用（dateTrashed 排序）。
                add(MediaStore.Images.Media.DATE_EXPIRES)
            }
        }.toTypedArray()
        val sortColumn = when (sortBy) {
            "name" -> MediaStore.Images.Media.DISPLAY_NAME
            "dateModified" -> MediaStore.Images.Media.DATE_MODIFIED
            "dateTrashed" -> MediaStore.Images.Media.DATE_EXPIRES
            else -> MediaStore.Images.Media.DATE_ADDED   // dateCreated 及未知值
        }

        // selection：bucket 过滤 + keyset 游标条件（复合 (sortColumn, _ID) 比较）
        val (selBuilder, argsList) = buildList<Pair<StringBuilder, MutableList<String>>> {
            val sb = StringBuilder()
            val args = mutableListOf<String>()
            if (bucketIds.isNotEmpty()) {
                val placeholders = bucketIds.joinToString(",") { "?" }
                sb.append("${MediaStore.Images.Media.BUCKET_ID} IN ($placeholders)")
                args.addAll(bucketIds)
            }
            // 收藏过滤（P1b）：仅查 IS_FAVORITE=1（Android R+）
            if (favoritesOnly && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                if (sb.isNotEmpty()) sb.append(" AND ")
                sb.append("${MediaStore.Images.Media.IS_FAVORITE} = 1")
            }
            // 回收站过滤（P1a）：默认排除(IS_TRASHED=0)；trashedOnly 仅查回收站(IS_TRASHED=1)。Android R+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                if (sb.isNotEmpty()) sb.append(" AND ")
                sb.append("${MediaStore.Images.Media.IS_TRASHED} = ${if (trashedOnly) 1 else 0}")
            }
            // keyset 游标：解析 "sortValue|id"，构造复合比较
            //   ASC  → (col > ?) OR (col = ? AND _ID > ?)
            //   DESC → (col < ?) OR (col = ? AND _ID < ?)
            // name 排序时 sortValue 是字符串；时间排序时是秒级整数（以字符串传，SQLite 会做类型转换）
            val parsed = parseCursor(afterCursor)
            if (parsed != null) {
                if (sb.isNotEmpty()) sb.append(" AND ")
                sb.append("(")
                if (asc) {
                    sb.append("($sortColumn > ?) OR ($sortColumn = ? AND ${MediaStore.Images.Media._ID} > ?)")
                } else {
                    sb.append("($sortColumn < ?) OR ($sortColumn = ? AND ${MediaStore.Images.Media._ID} < ?)")
                }
                sb.append(")")
                args.add(parsed.sortValue)
                args.add(parsed.sortValue)
                args.add(parsed.id)
            }
            add(sb to args)
        }.first()

        // 排序：复合 (sortColumn, _ID)，方向一致。
        // 注意：MediaStore ContentResolver 的 sortOrder 参数不支持 LIMIT 关键字
        // （真机会报 "Invalid token LIMIT"）。分页靠 keyset WHERE 条件 + 循环读 limit 条停止；
        // 多读一条用于判断 hasMore。
        val dir = if (asc) "ASC" else "DESC"
        val sortOrder = "$sortColumn $dir, ${MediaStore.Images.Media._ID} $dir"

        var nextCursor: String? = null
        try {
            val sel = selBuilder.toString().ifEmpty { null }
            val selArgs = argsList.toTypedArray().ifEmpty { null }
            val queryBundle = android.os.Bundle().apply {
                if (sel != null) {
                    putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, sel)
                    putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selArgs)
                }
                putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder)
                // 回收站过滤：trashedOnly 显式包含回收站项（默认 query 排除 IS_TRASHED=1）；
                // 普通视图显式排除（MANAGE_MEDIA app 默认包含，selection 在 ColorOS 上不可靠）
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    putInt(
                        MediaStore.QUERY_ARG_MATCH_TRASHED,
                        if (trashedOnly) MediaStore.MATCH_INCLUDE else MediaStore.MATCH_EXCLUDE
                    )
                }
            }
            contentResolver.query(collection, projection, queryBundle, null)?.use { cursor ->
                val idxId = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val idxName = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val idxSize = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val idxMime = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                val idxBucket = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
                val idxDate = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val idxDateModified = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
                val idxSort = cursor.getColumnIndexOrThrow(sortColumn)
                val idxFav = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    cursor.getColumnIndex(MediaStore.Images.Media.IS_FAVORITE) else -1
                val idxTrash = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    cursor.getColumnIndex(MediaStore.Images.Media.IS_TRASHED) else -1
                // DATE_EXPIRES（回收站删除日期）；非 R+ 或未查该列时 -1
                val idxDateExpires = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    cursor.getColumnIndex(MediaStore.Images.Media.DATE_EXPIRES) else -1
                // WIDTH/HEIGHT：标准列（全版本），个别格式/损坏项可能无值（-1 或 null → 0）
                val idxWidth = cursor.getColumnIndex(MediaStore.Images.Media.WIDTH)
                val idxHeight = cursor.getColumnIndex(MediaStore.Images.Media.HEIGHT)

                var lastSortRaw = ""
                var lastId = ""
                // 读最多 limit 条。循环内 moveToNext 推进；返回 false（无更多）则 break。
                // 这样读满 limit 条时 cursor 停在第 limit 条，退出后用 moveToNext 判断
                // 是否存在第 limit+1 条（决定 hasMore）。
                while (results.size < limit && cursor.moveToNext()) {
                    val id = cursor.getString(idxId) ?: continue
                    // 手动过滤回收站行：ColorOS 的 MATCH_TRASHED/selection 对
                    // MANAGE_MEDIA app 不可靠，代码级过滤保证普通视图永远
                    // 不含回收站项（回收站视图 trashedOnly 时保留）。
                    if (idxTrash >= 0 && !trashedOnly &&
                        cursor.getInt(idxTrash) == 1
                    ) {
                        continue
                    }
                    val name = cursor.getString(idxName) ?: continue
                    val size = if (cursor.isNull(idxSize)) 0L else cursor.getLong(idxSize)
                    val mime = cursor.getString(idxMime) ?: "image/*"
                    val bucketId = cursor.getString(idxBucket) ?: ""
                    val dateAdded = if (cursor.isNull(idxDate)) 0L else cursor.getLong(idxDate) * 1000
                    val dateModified = if (cursor.isNull(idxDateModified)) dateAdded
                    else cursor.getLong(idxDateModified) * 1000
                    val isFavorite = idxFav >= 0 && !cursor.isNull(idxFav) && cursor.getInt(idxFav) == 1
                    val isTrashed = idxTrash >= 0 && !cursor.isNull(idxTrash) && cursor.getInt(idxTrash) == 1
                    val dateTrashed = if (idxDateExpires >= 0 && !cursor.isNull(idxDateExpires))
                        cursor.getLong(idxDateExpires) * 1000 else 0L
                    val imgWidth = if (idxWidth >= 0 && !cursor.isNull(idxWidth)) cursor.getInt(idxWidth) else 0
                    val imgHeight = if (idxHeight >= 0 && !cursor.isNull(idxHeight)) cursor.getInt(idxHeight) else 0
                    results.add(MsImageInfo(id, name, size, mime, bucketId, dateAdded, dateModified, isFavorite, isTrashed, dateTrashed, imgWidth, imgHeight))
                    lastSortRaw = cursor.getString(idxSort) ?: ""
                    lastId = id
                }
                // 读满 limit 条后，cursor 停在第 limit 条。moveToNext 若 true，说明存在
                // 第 limit+1 条 → 有下一页；游标用本页最后一条（lastSortRaw/lastId）。
                if (results.size == limit && cursor.moveToNext() && results.isNotEmpty()) {
                    nextCursor = encodeCursor(lastSortRaw, lastId)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "scanImages 异常: ${e.message}")
        }
        Log.i(TAG, "scanImages: 本页 ${results.size} 张（limit=$limit, cursor=$afterCursor, hasMore=${nextCursor != null}, sortBy=$sortBy, asc=$asc）")
        return ScanPage(results, nextCursor)
    }

    /// 解析 keyset 游标 "sortValue|id"。
    private fun parseCursor(cursor: String?): CursorKey? {
        if (cursor.isNullOrEmpty()) return null
        val sep = cursor.indexOf('|')
        if (sep <= 0 || sep >= cursor.length - 1) return null
        return CursorKey(cursor.substring(0, sep), cursor.substring(sep + 1))
    }

    private fun encodeCursor(sortValue: String, id: String): String = "$sortValue|$id"

    private data class CursorKey(val sortValue: String, val id: String)

    /// keyset 分页结果（图片列表 + 下一页游标）。
    data class ScanPage(val images: List<MsImageInfo>, val nextCursor: String?) {
        fun toMap(): Map<String, Any?> = mapOf(
            "images" to images.map { it.toMap() },
            "nextCursor" to nextCursor,
        )
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

    // ──────────── 完整元数据 EXIF/GPS（P0）────────────

    /// 提取单图的完整元数据（EXIF/GPS/相机参数）。
    ///
    /// 优先用 AndroidX ExifInterface 读 JPEG/TIFF EXIF（朝向/GPS/时间/相机参数）；
    /// 若无 EXIF（如 PNG/RAW）则用 metadata-extractor 兜底多格式（IPTC/XMP/PNG）。
    /// 返回分组：{ "EXIF": {Make,Model,...}, "GPS": {Latitude,Longitude}, ... }。
    /// API<Q、流打开失败或格式不支持时返回 emptyMap（不抛错，调用方按空处理）。
    /// 移植自 aves MetadataFetchHandler + photo_manager IDBUtils.getExif。
    fun getMetadata(id: String): Map<String, Map<String, String>> {
        val longId = id.toLongOrNull() ?: return emptyMap()
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        val result = mutableMapOf<String, MutableMap<String, String>>()

        // 0) 文件绝对路径(MediaStore.DATA)。供详情面板显示完整路径。
        try {
            contentResolver.query(
                uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (idx >= 0) {
                        val data = c.getString(idx)
                        if (!data.isNullOrEmpty()) {
                            result.getOrPut("FILE") { mutableMapOf() }["Path"] = data
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getMetadata DATA 查询失败: ${e.message}")
        }

        // 1) ExifInterface 读 JPEG EXIF + GPS
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                val exif = androidx.exifinterface.media.ExifInterface(input)
                val exifGroup = result.getOrPut("EXIF") { mutableMapOf() }
                fun put(key: String, v: String?) {
                    if (!v.isNullOrEmpty()) exifGroup[key] = v
                }
                put("Make", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_MAKE))
                put("Model", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_MODEL))
                put("Software", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_SOFTWARE))
                put("FNumber", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_F_NUMBER))
                put("ExposureTime", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_EXPOSURE_TIME))
                put("ISO", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY))
                put("FocalLength", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_FOCAL_LENGTH))
                put("DateTime", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_DATETIME_ORIGINAL))
                put("Orientation", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_ORIENTATION))
                // 曝光补偿 EV(对标系统相册图片参数卡 ISO|EV|快门|光圈|焦距 五项)。
                // 值形如 "-3/10"(有理数,Dart 侧 formatEv 格式化为 "-0.3")。
                put("ExposureBiasValue", exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_EXPOSURE_BIAS_VALUE))
                val latLng = exif.latLong
                if (latLng != null) {
                    val gps = result.getOrPut("GPS") { mutableMapOf() }
                    gps["Latitude"] = latLng[0].toString()
                    gps["Longitude"] = latLng[1].toString()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getMetadata ExifInterface 失败: ${e.message}")
        }

        // 2) metadata-extractor 兜底（无 EXIF 的格式）。仅当 ExifInterface 未取到字段时启用。
        if (result.isEmpty()) {
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    val md = com.drew.imaging.ImageMetadataReader.readMetadata(input)
                    for (directory in md.directories) {
                        val g = result.getOrPut(directory.name) { mutableMapOf() }
                        for (tag in directory.tags) {
                            if (!g.containsKey(tag.tagName)) {
                                g[tag.tagName] = tag.description ?: ""
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "getMetadata metadata-extractor 失败: ${e.message}")
            }
        }
        return result
    }

    // ──────────── 收藏/取消收藏（P1b）────────────

    /// 构造批量收藏/取消收藏请求（Android R+）。
    /// favorite=true 收藏，false 取消。返回 IntentSender（系统弹窗确认）；
    /// <R 返回 null（不支持）。移植自 photo_manager PhotoManagerFavoriteManager。
    fun requestFavorite(ids: List<String>, favorite: Boolean): IntentSender? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (ids.isEmpty()) return null
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        return try {
            MediaStore.createFavoriteRequest(contentResolver, uris, favorite).intentSender
        } catch (e: Exception) {
            Log.w(TAG, "requestFavorite 失败: ${e.message}")
            null
        }
    }

    // ──────────── 回收站（P1a）────────────

    /// 构造批量移入回收站请求（Android R+）。返回 IntentSender（系统弹窗确认）；不支持返回 null。
    /// 移植自 photo_manager PhotoManagerDeleteManager.moveToTrashInApi30。
    fun requestTrash(ids: List<String>): IntentSender? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (ids.isEmpty()) return null
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        return try {
            MediaStore.createTrashRequest(contentResolver, uris, true).intentSender
        } catch (e: Exception) {
            Log.w(TAG, "requestTrash 失败: ${e.message}")
            null
        }
    }

    /// 构造批量从回收站恢复请求（Android R+）。
    fun requestRestore(ids: List<String>): IntentSender? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (ids.isEmpty()) return null
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        return try {
            MediaStore.createTrashRequest(contentResolver, uris, false).intentSender
        } catch (e: Exception) {
            Log.w(TAG, "requestRestore 失败: ${e.message}")
            null
        }
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

    // ──────────── 下采样解码（viewer 全图用,对标系统相册 native 解码速度） ────────────

    /// 从原图 BitmapFactory + inSampleSize 解码到 ≤ [targetWidth],再 compress JPEG 95。
    ///
    /// 对比 [readBytes]（读全图字节交 Dart decode 全 12MP,JPEG 全解码慢）:
    /// 本方法 native 端只解码 targetWidth 附近像素(inSampleSize 下采样,
    /// 不解全 1200 万像素),JPEG 95 高质量压缩后交 Dart decode 小图——
    /// 解码量 12MP → ~3MP,相机大图全图解码 ~250ms → ~80-100ms,质量从原图解码保证清晰。
    /// (系统相册走私有 native libcodec 区域解码;visort 用标准 BitmapFactory
    ///  + inSampleSize 下采样,同样只解目标尺寸像素,够用。)
    fun readSampledImage(id: String, targetWidth: Int): Map<String, Any> {
        val longId = id.toLongOrNull() ?: throw MsError.InvalidArg("非法图片 id: $id")
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        // ① 读原图尺寸(不解码像素,inJustDecodeBounds)。用 openInputStream + BufferedInputStream:
        //    decodeStream 解 JPEG 需要 markable stream(openInputStream 的 FileInputStream 不可 mark,
        //    直接 decodeStream 会空/黑);BufferedInputStream 提供缓冲 mark。
        //    (openFileDescriptor 对部分 MediaStore uri 返回 null,故不用 fd 路径。)
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // ⚠️ openInputStream 判 null 必须独立:use 块返回 decodeStream 结果,
        // inJustDecodeBounds 时 decodeStream 正常返回 null,若写 `?.use{} ?: throw`
        // 会把这个 null 误判成失败而 throw(之前一直 FAIL 的根因)。
        val bStream = contentResolver.openInputStream(uri)
            ?: throw MsError.QueryFailed("无法打开 InputStream: $id")
        bStream.use {
            BitmapFactory.decodeStream(BufferedInputStream(it, 65536), null, boundsOpts)
        }
        val origW = boundsOpts.outWidth
        if (origW <= 0) {
            // 尺寸读不出(非图片/损坏)→ 抛异常,由 dart 端 catch 走 readBytes 兜底
            throw MsError.QueryFailed("readSampledImage: 无法读尺寸 id=$id")
        }
        // ② 算 inSampleSize(2 的幂,使解码宽度 ≤ targetWidth)。
        //    ⚠️ 用 origW/sampleSize > targetWidth(非 origW/(sample*2) >= target):
        //    后者要求 origW >= 2*target 才下采样,对 origW≈target 的相机原图(3072 vs 2880)
        //    会得 sample=1 → 解全图 12MP + compress 大 JPEG + dart 再解一遍,比 readBytes 还慢。
        //    改成 > targetWidth:只要 origW > target 就 sample≥2,解码宽度落到 (target/2, target]。
        //    例:origW=3072, target=2880 → sample=2(解码 1536);origW=4096 → sample=2(解码 2048)。
        var sampleSize = 1
        while (origW / sampleSize > targetWidth) {
            sampleSize *= 2
        }
        // ③ 按 inSampleSize 解码(只解 origW/sampleSize 像素,native libjpeg-turbo 快)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val dStream = contentResolver.openInputStream(uri)
            ?: throw MsError.QueryFailed("无法打开 InputStream: $id")
        val bitmap = dStream.use {
            BitmapFactory.decodeStream(BufferedInputStream(it, 65536), null, opts)
        } ?: throw MsError.QueryFailed("无法解码 id=$id")
        // ④ 直接拷贝 ARGB_8888 原始像素(不 compress JPEG):省掉 JPEG encode + dart 再
        //    decode 两步 codec。copyPixelsToBuffer 字节序 RGBA(= Flutter rgba8888)。
        val w = bitmap.width
        val h = bitmap.height
        val pixels = ByteArray(w * h * 4)
        bitmap.copyPixelsToBuffer(ByteBuffer.wrap(pixels))
        bitmap.recycle()
        return mapOf("pixels" to pixels, "width" to w, "height" to h)
    }

    // ──────────── 读取缩略图（相册网格用） ────────────

    /// 读取单图缩略图字节（JPEG 编码）。
    ///
    /// API 29+ 用 ContentResolver.loadThumbnail（系统级高效，返回指定尺寸的 Bitmap）。
    /// API <29 不支持 loadThumbnail，返回空数组 —— Dart 侧检测到空回退 readBytes 全图下采样。
    ///
    /// 磁盘缩略图缓存（对标系统相册 mem→disk 两级缓存）：首次 loadThumbnail + 编码后
    /// 落盘 {cacheDir}/visort_thumb/{width}x{height}/{id}.jpg，二次进入零解码直出；
    /// [dateModifiedMs]（源图 DATE_MODIFIED 毫秒）非空时用文件 mtime 校验源图是否
    /// 编辑过——编辑后 mtime < 新 dateModified → 自动失效重取，零额外查询。
    /// 容量上限 [MAX_THUMBNAIL_CACHE_BYTES]，超出按 mtime 删最旧。
    ///
    /// [width]/[height] 为目标缩略图像素尺寸（如 256x256）。
    fun readThumbnail(
        id: String,
        width: Int = 256,
        height: Int = 256,
        dateModifiedMs: Long? = null,
    ): ByteArray {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // 低版本不支持 loadThumbnail，返回空让 Dart 回退
            Log.d(TAG, "readThumbnail: API <29，跳过（id=$id）")
            return ByteArray(0)
        }
        val longId = id.toLongOrNull() ?: throw MsError.InvalidArg("非法图片 id: $id")

        // ① 磁盘缓存命中 → 零解码直出
        readThumbnailCache(longId, width, height, dateModifiedMs)?.let { return it }

        // ② 小尺寸请求（占位层）优先 EXIF 内嵌缩略图（对标系统相册 fo0.java）：
        //    相机 JPEG 内嵌 160×120 缩略图，解码 ~1-5ms，免系统 loadThumbnail
        //    服务首次生成的 50~200ms —— 首屏占位秒显的关键。
        //    无 EXIF 时回退 loadThumbnail（小尺寸采样少，也快于大尺寸）。
        if (width <= EXIF_THUMBNAIL_MAX_SIZE && height <= EXIF_THUMBNAIL_MAX_SIZE) {
            exifThumbnail(longId)?.let { bytes ->
                writeThumbnailCache(longId, width, height, dateModifiedMs, bytes)
                return bytes
            }
        }

        // ③ 未命中 → loadThumbnail + 编码。信号量限制并发：首屏 20+ 张同时
        //    压系统 MediaStore 缩略图服务会造成 CPU 尖峰与排队抖动。
        val bitmap: Bitmap
        thumbnailSemaphore.acquire()
        try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
            )
            bitmap = try {
                contentResolver.loadThumbnail(uri, Size(width, height), null)
            } catch (e: Exception) {
                throw MsError.QueryFailed("loadThumbnail 失败 id=$id: ${e.message}")
            }
        } finally {
            thumbnailSemaphore.release()
        }
        val baos = ByteArrayOutputStream()
        // 质量 90→70：网格缩略图场景视觉无损（300~500px），编码更快、字节更小、
        // Dart 侧解码更快 —— 三重收益。
        bitmap.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        val bytes = baos.toByteArray()
        writeThumbnailCache(longId, width, height, dateModifiedMs, bytes)
        return bytes
    }

    /// 读取 JPEG 内嵌 EXIF 缩略图（无则返回 null）。
    /// 仅 JPEG 文件含 EXIF 区；HEIC/PNG 等走回退路径。
    private fun exifThumbnail(id: Long): ByteArray? {
        return try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
            )
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { stream ->
                val exif = ExifInterface(stream)
                if (!exif.hasThumbnail()) return null
                val bmp = exif.getThumbnailBitmap() ?: return null
                val baos = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 70, baos)
                Log.d(TAG, "readThumbnail: EXIF 命中 id=$id ${bmp.width}x${bmp.height} ${baos.size()}B")
                baos.toByteArray()
            }
        } catch (e: Exception) {
            Log.d(TAG, "readThumbnail: EXIF 失败 id=$id: ${e.message}")
            null
        }
    }

    // ──────────── 缩略图磁盘缓存 ────────────

    /// 命中条件：文件存在 &&（无 dateModifiedMs 校验 或 文件 mtime ≥ 源图 DATE_MODIFIED）。
    /// 写入时把文件 mtime 对齐源图 DATE_MODIFIED（秒级值×1000 后的毫秒），
    /// 图片被编辑后 dateModified 增大 → mtime 落后 → 此处判失效删文件重取。
    private fun readThumbnailCache(
        id: Long,
        width: Int,
        height: Int,
        dateModifiedMs: Long?,
    ): ByteArray? {
        val file = File(File(thumbnailCacheDir, "${width}x$height"), "$id.jpg")
        if (!file.exists()) return null
        val dm = dateModifiedMs
        if (dm == null || file.lastModified() >= dm) {
            return try { file.readBytes() } catch (e: Exception) { null }
        }
        file.delete()
        return null
    }

    private fun writeThumbnailCache(
        id: Long,
        width: Int,
        height: Int,
        dateModifiedMs: Long?,
        bytes: ByteArray,
    ) {
        try {
            val dir = File(thumbnailCacheDir, "${width}x$height")
            dir.mkdirs()
            val file = File(dir, "$id.jpg")
            file.writeBytes(bytes)
            // mtime 对齐源图 dateModified（毫秒）→ 命中校验依据；无校验来源时用当前时间
            file.setLastModified(max(System.currentTimeMillis(), dateModifiedMs ?: 0L))
            trimThumbnailCache()
        } catch (e: Exception) {
            Log.w(TAG, "writeThumbnailCache 失败: ${e.message}")
        }
    }

    /// 容量上限：超出按 mtime 删最旧，直到达标。目录小（≤128MB）时跳过扫描。
    private fun trimThumbnailCache() {
        val files = thumbnailCacheDir.listFiles()?.filter { it.isFile } ?: return
        var total = 0L
        for (f in files) total += f.length()
        if (total <= MAX_THUMBNAIL_CACHE_BYTES) return
        val sorted = files.sortedBy { it.lastModified() }
        for (f in sorted) {
            if (total <= MAX_THUMBNAIL_CACHE_BYTES) break
            val len = f.length()
            if (f.delete()) total -= len
        }
    }

    /// 缩略图磁盘缓存目录（app cache，系统可清）。
    private val thumbnailCacheDir: File by lazy {
        File(context.cacheDir, "visort_thumb").apply { mkdirs() }
    }

    companion object {
        /// 缩略图 loadThumbnail+编码 并发上限（与 ioExecutor 12 线程匹配，
        /// 对标系统相册 BaseThumbnailLoader 12 并发）。
        private val thumbnailSemaphore = Semaphore(12)

        /// 磁盘缩略图缓存容量上限（128MB ≈ 数千张 300~500px JPEG）。
        private const val MAX_THUMBNAIL_CACHE_BYTES = 128L * 1024 * 1024

        /// EXIF 内嵌缩略图适用的最大请求尺寸（px）：≤128 的占位层请求
        /// 优先走 EXIF（~5ms），更大请求直接 loadThumbnail（EXIF 图糊）。
        private const val EXIF_THUMBNAIL_MAX_SIZE = 128
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
        } catch (e: RecoverableSecurityException) {
            e.userAction.actionIntent.intentSender
        }
    }
}
