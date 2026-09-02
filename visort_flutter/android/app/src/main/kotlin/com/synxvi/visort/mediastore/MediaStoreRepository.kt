package com.synxvi.visort.mediastore

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.IntentSender
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// ───────────────────────── MediaStore 业务层 ─────────────────────────
//
// 封装 MediaStore.Images.Media 查询 + 删除（Recovery API）。
//
// 核心方法：
//   - listBuckets()      : 按 BUCKET_ID 分组列出所有相册（名+数量）
//   - scanImages(ids)    : 按 bucket id 列表查询图片
//   - readMeta(id)       : 单图元信息
//   - readBytes(id, max) : 读字节流（图片加载用）
//   - createDeleteRequest(ids) : 构造批量删除请求（createDeleteRequest 系统弹窗）

private const val TAG = "MsRepository"

/// MediaStore Images 外部存储的 authority 常量。
/// Dart 侧 ImageRef.root 编码此值，ImageRef.relativePath 编码 _ID。
const val IMAGES_AUTHORITY = "content://media/external/images/media"

class MediaStoreRepository(private val context: Context) {

    private val contentResolver: ContentResolver get() = context.contentResolver

    /// 外部存储图片集合 URI（minSdk 30：getContentUri 恒可用）
    private val collection: Uri
        get() = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)

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
            // 与 scanImages 一致：Bundle query 显式排除回收站项。
            // 旧式 selection 参数在 ColorOS 上对 MANAGE_MEDIA 应用不生效
            // （默认查询含回收站项，导致删除后首页 count/封面不更新）。
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
        } catch (e: Exception) {
            // 上抛而非吞掉返回空列表：空列表会被 Dart 当「图库为空」渲染
            // 首页空画廊（UI 撒谎、无重试入口）。Plugin 层 catch 转 error，
            // Dart 显示加载失败态可重试。
            Log.w(TAG, "listBuckets 异常: ${e.message}")
            throw e
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
        // 代码级手动跳过回收站行，保证 count/coverId 永远不含回收站项。
        val idxTrash = cursor.getColumnIndex(MediaStore.Images.Media.IS_TRASHED)
        data class Agg(
            val name: String, var count: Int, val coverId: String?,
            var minDateAdded: Long = Long.MAX_VALUE, var maxDateModified: Long = 0L,
        )
        val agg = mutableMapOf<String, Agg>()
        while (cursor.moveToNext()) {
            if (idxTrash >= 0 && cursor.getInt(idxTrash) == 1) continue
            val bid = cursor.getString(idxId) ?: continue
            val bname = cursor.getString(idxName) ?: ""
            // BUCKET_DISPLAY_NAME 为 null（无桶名根级项）→ 空串，Dart 侧
            // UI 按 i18n 'root_dir' 渲染。不在 Kotlin 产中文文案。
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
            // EXIF 方向（0/90/180/270）：HEIC 尺寸复核时交换宽高用（对齐 Q+ 显示尺寸语义）
            add(MediaStore.Images.Media.ORIENTATION)
            // IS_FAVORITE/IS_TRASHED/DATE_EXPIRES（minSdk 30 恒在）：
            // 收藏/回收站标记 + 回收站过期时间（移入回收站时刻 + 30 天，
            // 作「删除日期」排序键，仅回收站视图 dateTrashed 排序使用）。
            add(MediaStore.Images.Media.IS_FAVORITE)
            add(MediaStore.Images.Media.IS_TRASHED)
            add(MediaStore.Images.Media.DATE_EXPIRES)
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
            // 收藏过滤（P1b）：仅查 IS_FAVORITE=1
            if (favoritesOnly) {
                if (sb.isNotEmpty()) sb.append(" AND ")
                sb.append("${MediaStore.Images.Media.IS_FAVORITE} = 1")
            }
            // 回收站过滤（P1a）：默认排除(IS_TRASHED=0)；trashedOnly 仅查回收站(IS_TRASHED=1)
            if (sb.isNotEmpty()) sb.append(" AND ")
            sb.append("${MediaStore.Images.Media.IS_TRASHED} = ${if (trashedOnly) 1 else 0}")
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
        // date_expires ASC 在部分设备(ColorOS)查询返回空,统一 DESC 查询,
        // asc 由结果反转实现(见 return 前)。仅 dateTrashed(DATE_EXPIRES) 受影响。
        val queryAsc = asc && sortBy != "dateTrashed"
        val dir = if (queryAsc) "ASC" else "DESC"
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
                putInt(
                    MediaStore.QUERY_ARG_MATCH_TRASHED,
                    if (trashedOnly) MediaStore.MATCH_INCLUDE else MediaStore.MATCH_EXCLUDE
                )
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
                val idxFav = cursor.getColumnIndex(MediaStore.Images.Media.IS_FAVORITE)
                val idxTrash = cursor.getColumnIndex(MediaStore.Images.Media.IS_TRASHED)
                // DATE_EXPIRES（回收站删除日期）
                val idxDateExpires = cursor.getColumnIndex(MediaStore.Images.Media.DATE_EXPIRES)
                // WIDTH/HEIGHT：标准列（全版本），个别格式/损坏项可能无值（-1 或 null → 0）
                val idxWidth = cursor.getColumnIndex(MediaStore.Images.Media.WIDTH)
                val idxHeight = cursor.getColumnIndex(MediaStore.Images.Media.HEIGHT)
                val idxOrient = cursor.getColumnIndex(MediaStore.Images.Media.ORIENTATION)

                var lastSortRaw = ""
                var lastId = ""
                // 读最多 limit 条。循环内 moveToNext 推进；返回 false（无更多）则 break。
                // 这样读满 limit 条时 cursor 停在第 limit 条，退出后用 moveToNext 判断
                // 是否存在第 limit+1 条（决定 hasMore）。
                while (results.size < limit && cursor.moveToNext()) {
                    val id = cursor.getString(idxId) ?: continue
                    // 手动双向过滤：ColorOS 的 MATCH_TRASHED/selection(IS_TRASHED) 对
                    // MANAGE_MEDIA app 不可靠,代码级兜底——
                    // 普通视图(!trashedOnly)跳过回收站项(IS_TRASHED=1);
                    // 回收站视图(trashedOnly)跳过非回收站项(IS_TRASHED=0),
                    // 否则 selection 失效时普通图片会混入回收站。
                    if (idxTrash >= 0) {
                        val isTrashedRow = !cursor.isNull(idxTrash) && cursor.getInt(idxTrash) == 1
                        if (isTrashedRow != trashedOnly) continue
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
                    var imgWidth = if (idxWidth >= 0 && !cursor.isNull(idxWidth)) cursor.getInt(idxWidth) else 0
                    var imgHeight = if (idxHeight >= 0 && !cursor.isNull(idxHeight)) cursor.getInt(idxHeight) else 0
                    // HEIC/HEIF：MediaStore 对部分机型报错误尺寸（aves 同修，见
                    // aves MediaStoreImageProvider 复核逻辑）——inJustDecodeBounds
                    // 读容器真实尺寸覆盖。仅 HEIC 行付一次流头读成本，JPEG/PNG 零开销。
                    if (mime == "image/heic" || mime == "image/heif") {
                        val orient = if (idxOrient >= 0 && !cursor.isNull(idxOrient)) cursor.getInt(idxOrient) else 0
                        val longId = id.toLongOrNull()
                        if (longId != null) {
                            val uri = ContentUris.withAppendedId(
                                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
                            )
                            heicVerifiedSize(id, uri, orient, dateModified)?.let { (w, h) ->
                                imgWidth = w; imgHeight = h
                            }
                        }
                    }
                    // isHdr 不在此检测：scan 路径保持零文件 IO（曾把 64KB 头读
                    // 塞进 scan，全 JPEG 大相册一把梭页 = 几十秒，真机卡死实证）。
                    // HDR 走独立后台批量通道 detectHdrs，网格先上屏后补徽标
                    // （aves cataloguing 同语义：快字段先出，慢元数据异步到货）。
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
            // 上抛而非吞掉返回空页：空页+nextCursor=null 会被 Dart 当
            // 「无更多数据」，相册分页本会话静默截断（后续照片全部不可达、
            // 无错误无重试）。Plugin 层 catch 转 error，Dart 显示失败态。
            Log.w(TAG, "scanImages 异常: ${e.message}")
            throw e
        }

        // dateTrashed + asc：ColorOS 上 DATE_EXPIRES 直接 ASC 查询返回空
        //（真机实证）→ 恒 DESC 查询取最新页再整体反转出升序窗口。
        // 游标推进修复：DESC 查询的 keyset 条件是"比上一页最后一条更旧"，
        // 反转后本页最后一条（最旧）即是查询序最后一条——用它 encode 游标
        // 让下一页继续向前取，旧项不再永久不可达。窗口语义局限（非全局
        // 升序分页，而是"最近 N 条按升序排"，>60 条回收站时最旧项仍
        // 滞后一页可达）随设备支持 ASC 查询后消除。
        if (sortBy == "dateTrashed" && asc && results.size > 1) {
            results.reverse()
        }
        Log.i(TAG, "scanImages: 本页 ${results.size} 张（limit=$limit, cursor=$afterCursor, hasMore=${nextCursor != null}, sortBy=$sortBy, asc=$asc）")
        return ScanPage(results, nextCursor)
    }

    /// 解析 keyset 游标 "sortValue|id"。
    /// 用 lastIndexOf 从右切：id 是 MediaStore _ID 纯数字串永不含 '|'，
    /// 而 name 排序时 sortValue=DISPLAY_NAME 合法可含 '|'（"a|b.jpg"）——
    /// 旧 indexOf 取第一个 '|' 会把 "a|b|123" 切成 ("a", "b|123")，
    /// 下一页 keyset 条件错乱（跳页/重复）。
    /// sortValue 为空（NULL 列已规格化 ""）时返回 null——分页保守终止，
    /// 不会重复。
    private fun parseCursor(cursor: String?): CursorKey? {
        if (cursor.isNullOrEmpty()) return null
        val sep = cursor.lastIndexOf('|')
        if (sep <= 0 || sep >= cursor.length - 1) return null
        return CursorKey(cursor.substring(0, sep), cursor.substring(sep + 1))
    }

    private fun encodeCursor(sortValue: String, id: String): String = "$sortValue|$id"

    private data class CursorKey(val sortValue: String, val id: String)

    /// keyset 分页结果（图片列表 + 下一页游标）。
    data class ScanPage(val images: List<MsImageInfo>, val nextCursor: String?) {
        // 扁平化传输：12 个并行数组代替 List<Map>，减少 MethodChannel 序列化
        // 开销（实测 1105 项 List<Map> ~160ms → 并行数组显著更省）。Dart 按索引重组。
        fun toMap(): Map<String, Any?> = mapOf(
            "ids" to images.map { it.id },
            "names" to images.map { it.name },
            "sizes" to images.map { it.size },
            "mimes" to images.map { it.mime },
            "bucketIds" to images.map { it.bucketId },
            "dateAddeds" to images.map { it.dateAddedMs },
            "dateModifieds" to images.map { it.dateModifiedMs },
            "isFavorites" to images.map { it.isFavorite },
            "isTrasheds" to images.map { it.isTrashed },
            "dateTrasheds" to images.map { it.dateTrashedMs },
            "widths" to images.map { it.width },
            "heights" to images.map { it.height },
            "isHdrs" to images.map { it.isHdr },
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
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.ORIENTATION,
        )
        try {
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0) ?: id
                    val size = if (cursor.isNull(1)) 0L else cursor.getLong(1)
                    val modified = if (cursor.isNull(2)) 0L else cursor.getLong(2) * 1000
                    var width = if (cursor.isNull(3)) 0 else cursor.getInt(3)
                    var height = if (cursor.isNull(4)) 0 else cursor.getInt(4)
                    val mime = cursor.getString(5)
                    // HEIC 尺寸复核（同 scanImages，单图调用频率低，成本可忽略）
                    if (mime == "image/heic" || mime == "image/heif") {
                        val orient = if (cursor.isNull(6)) 0 else cursor.getInt(6)
                        heicVerifiedSize(id, uri, orient, modified)?.let { (w, h) ->
                            width = w; height = h
                        }
                    }
                    return MsMetaInfo(name, size, modified, width, height)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "readMeta 异常: ${e.message}")
        }
        throw MsError.QueryFailed("无法读取图片元信息: $id")
    }

    // ──────────── 搜索索引（批量 EXIF：拍摄时间 + GPS + 相机，供搜索页分类）────────────

    /// EXIF DateTimeOriginal 格式（"yyyy:MM:dd HH:mm:ss"，本地时间无时区）。
    /// isLenient=false：脏 EXIF（"0000:00:00 00:00:00"）lenient 下会解析成
    /// 怪日期而非抛异常（子代理审查 P3），严格模式直接 null。
    private val exifDateFormat = java.text.SimpleDateFormat(
        "yyyy:MM:dd HH:mm:ss", java.util.Locale.US
    ).apply { isLenient = false }

    /// 批量提取搜索索引所需元数据（Dart 侧分批传入、累计进度；设置页
    /// 「智能识别」区展示）。逐张单次 openInputStream + androidx
    /// ExifInterface——只读文件头 EXIF 区，单张约几 ms，一次 pass 同时
    /// 取拍摄时间（DateTimeOriginal→DateTime 兜底）、GPS、相机制造商/
    /// 型号（拼 "Make Model"）。
    /// 返回 id → { dateTakenMs / lat / lng / camera }——全部请求项都
    /// 返回（含各字段全 null 的「无 EXIF 空行」tombstone，2026-09 审查
    /// P1-4：此前只返回非空项，无 EXIF 照片永不入表 → 每次进页都被判
    /// 新照片整批重扫，差集永不收敛）。openInputStream 失败（损坏/
    /// 权限）仍跳过——异常场景允许下轮重试。
    fun indexSearchMeta(ids: List<String>): Map<String, Map<String, Any?>> {
        val out = mutableMapOf<String, Map<String, Any?>>()
        for (id in ids) {
            try {
                val uri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLongOrNull() ?: -1L
                )
                contentResolver.openInputStream(uri)?.use { input ->
                    val exif = androidx.exifinterface.media.ExifInterface(input)
                    var dateTakenMs: Long? = null
                    for (tag in listOf(
                        androidx.exifinterface.media.ExifInterface.TAG_DATETIME_ORIGINAL,
                        androidx.exifinterface.media.ExifInterface.TAG_DATETIME,
                    )) {
                        val raw = exif.getAttribute(tag)
                        if (raw.isNullOrEmpty()) continue
                        // SimpleDateFormat 非线程安全，ioExecutor 多线程调用须同步
                        dateTakenMs = try {
                            synchronized(exifDateFormat) { exifDateFormat.parse(raw)?.time }
                        } catch (e: Exception) {
                            null
                        }
                        if (dateTakenMs != null) break
                    }
                    val latLng = exif.latLong
                    val make = exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_MAKE)?.trim()
                    val model = exif.getAttribute(androidx.exifinterface.media.ExifInterface.TAG_MODEL)?.trim()
                    val camera = listOfNotNull(
                        if (model != null && make != null && !model.contains(make)) make else null,
                        model ?: make,
                    ).joinToString(" ").ifEmpty { null }
                    // 无条件入表：空 EXIF 也返回（tombstone，见方法注释）。
                    out[id] = mapOf(
                        "dateTakenMs" to dateTakenMs,
                        "lat" to latLng?.get(0),
                        "lng" to latLng?.get(1),
                        "camera" to camera,
                    )
                }
            } catch (e: Exception) {
                // 单张失败跳过（损坏/权限），不打断整批索引
            }
        }
        return out
    }

    // ──────────── 反地理编码（经纬度 → 国家/省/市，搜索页「地点」分类）────────────

    /// 坐标去重网格（度）：0.02° ≈ 2km，同城照片合并为一次 Geocoder 调用。
    private val geocodeGrid = 0.02

    /// 地理编码坐标缓存（网格 key → 地名三元组），跨批存活减少重复调用。
    /// ConcurrentHashMap：索引双循环竞态下（load 覆写 running 已修，但防御
    /// 未来并发路径）HashMap 并发写可丢条目/损坏（子代理审查 P1）。
    private val geocodeCache =
        java.util.concurrent.ConcurrentHashMap<String, Triple<String?, String?, String?>>()

    /// 批量反地理编码：入参 [lat, lng] 列表，出参同长度数组，每项
    /// { country / adminArea(省) / locality(市) }——Geocoder 不可用或
    /// 无结果时各字段为 null（Dart 侧降级回坐标网格分组）。
    ///
    /// 实现（对标 Aves GeocodingHandler）：android.location.Geocoder 走
    /// 系统定位服务（国行 ROM 多为厂商自带实现，可返回中文地名）；
    /// 0.02° 网格去重后串行调用（Geocoder 是网络请求，避免并发限流）。
    fun geocodePlaces(coords: List<List<Double>>): List<Map<String, String?>> {
        val geocoderAvailable = android.location.Geocoder.isPresent()
        val out = mutableListOf<Map<String, String?>>()
        for (pair in coords) {
            if (pair.size < 2) {
                out.add(emptyMap()); continue
            }
            val lat = pair[0]; val lng = pair[1]
            val key = "${(lat / geocodeGrid).roundToInt()}:${(lng / geocodeGrid).roundToInt()}"
            val hit = geocodeCache[key]
            if (hit != null || !geocoderAvailable) {
                out.add(hit?.let { mapOf("country" to it.first, "adminArea" to it.second, "locality" to it.third) } ?: emptyMap())
                continue
            }
            var resolved: Triple<String?, String?, String?>? = null
            try {
                val geocoder = android.location.Geocoder(context, java.util.Locale.CHINA)
                // maxResults=2：部分 ROM maxResults=1 时偶发返回空（Aves 同款规避）
                val addresses = geocoder.getFromLocation(lat, lng, 2)
                if (!addresses.isNullOrEmpty()) {
                    val a = addresses.first()
                    resolved = Triple(
                        a.countryName?.takeIf { it.isNotEmpty() },
                        a.adminArea?.takeIf { it.isNotEmpty() },
                        // 市级兜底链：locality → subLocality（Aves 同款 locality 优先）
                        (a.locality?.takeIf { it.isNotEmpty() })
                            ?: a.subLocality?.takeIf { it.isNotEmpty() },
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "geocodePlaces 异常: ${e.message}")
            }
            // 失败（异常/无结果）不落缓存：多为暂时性（无网/服务未就绪），
            // 缓存会让坐标在进程内永久无名且补解析轮也命中失败缓存
            // （子代理审查 P2）；仅成功结果跨批复用。
            if (resolved != null) {
                geocodeCache[key] = resolved
            }
            out.add(mapOf("country" to resolved?.first, "adminArea" to resolved?.second, "locality" to resolved?.third))
        }
        return out
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

        // 1) ExifInterface 读 JPEG EXIF + GPS。
        // 组懒建：无条件 getOrPut 会让 PNG/WebP 等无 EXIF 格式也产生
        // 空 "EXIF" 组——既污染 Dart 侧返回，又使下方 metadata-extractor
        // 兜底的 result.isEmpty() 恒 false（兜底永不可达，真机实证）。
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                val exif = androidx.exifinterface.media.ExifInterface(input)
                val exifGroup = mutableMapOf<String, String>()
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
                if (exifGroup.isNotEmpty()) result["EXIF"] = exifGroup
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

        // 2) metadata-extractor 兜底（PNG/WebP/IPTC/XMP 等无 ExifInterface
        // 字段的格式）。条件看 EXIF/GPS 是否取到——FILE.Path 几乎恒有值，
        // 不能作为"有元数据"的证据（旧 isEmpty 判断因此永假，兜底不可达）。
        if (result["EXIF"] == null && result["GPS"] == null) {
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

    /// 构造批量收藏/取消收藏请求。favorite=true 收藏，false 取消。
    /// 返回 IntentSender（系统弹窗确认）；空集返回 null。
    /// 移植自 photo_manager PhotoManagerFavoriteManager。
    fun requestFavorite(ids: List<String>, favorite: Boolean): IntentSender? {
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

    /// 构造批量移入回收站请求。返回 IntentSender（系统弹窗确认）；空集返回 null。
    /// 移植自 photo_manager PhotoManagerDeleteManager.moveToTrashInApi30。
    fun requestTrash(ids: List<String>): IntentSender? {
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

    /// 构造批量从回收站恢复请求。
    fun requestRestore(ids: List<String>): IntentSender? {
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
    ///
    /// EXIF orientation 应用(对标 aves/系统相册):BitmapFactory 不读 EXIF 方向,
    /// 竖拍照片解出横躺位图;Dart 侧 coverRatio 用 MediaStore WIDTH/HEIGHT
    /// (Q+ 已是旋转后显示尺寸)→ 位图与框宽高比不符。故解码后按 EXIF 方向
    /// Matrix 旋转,返回已是正立位图。网格路径 loadThumbnail 系统自动旋转,不受影响。
    fun readSampledImage(id: String, targetWidth: Int): Map<String, Any> {
        // 防御性 clamp：targetWidth 由 Dart 侧按屏宽算（无上限），误传/异常
        // DPR 会解出超大位图（ARGB_8888 ×4 字节/像素，直方 ROM OOM）。
        // 上限 4096px：解码后 ∈ (target/2, target]，4096 宽 ≈ 33MP 内安全；
        // 网格/查看器视觉需求最低 960。
        val safeTarget = targetWidth.coerceIn(960, 4096)
        val longId = id.toLongOrNull() ?: throw MsError.InvalidArg("非法图片 id: $id")
        // ⓪ 磁盘缓存（对标系统相册 screenNail 的 MEMORY_AND_DISK 磁盘层）：
        // 首次解码成功后落盘 targetWidth 宽 JPEG（已采样+EXIF 转正，二次读
        // 只需 decodeByteArray ~20-30ms vs 原路径 inJustDecodeBounds+全解码
        // +旋转 ~96ms）。viewer 回访/甩回程滚动期间 full 命中率大涨 = 滚动
        // 清晰度的主要来源。失效与清理同 thumb 缓存（mtime 校验 + LRU trim）。
        readFullCache(longId, safeTarget)?.let { return it }
        val bitmap = decodeSampledBitmap(longId, safeTarget)
        // ④' 落盘 screenNail JPEG（quality 90，已采样+转正；PNG 源存 JPEG 视觉
        // 无损级）：同步写 ~150KB，读路径跑 ioExecutor 可接受。失败不阻断
        //（缓存纯加速器）。写后再 copy 像素（compress 只读位图不销毁）。
        writeFullCache(longId, safeTarget, bitmap)
        val w = bitmap.width
        val h = bitmap.height
        // ④ 直接拷贝 ARGB_8888 原始像素(不 compress JPEG):省掉 JPEG encode + dart 再
        //    decode 两步 codec。copyPixelsToBuffer 字节序 RGBA(= Flutter rgba8888)。
        val pixels = ByteArray(w * h * 4)
        bitmap.copyPixelsToBuffer(ByteBuffer.wrap(pixels))
        bitmap.recycle()
        return mapOf("pixels" to pixels, "width" to w, "height" to h)
    }

    /// 原图 → ≤[safeTarget] 宽的转正位图（inSampleSize 下采样 + EXIF 旋转），
    /// 不落盘不拷像素——readSampledImage（在线路径）与 precacheFullImage
    ///（空闲预生成）共用的解码核。
    private fun decodeSampledBitmap(longId: Long, safeTarget: Int): Bitmap {
        val id = longId.toString()
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
        val origH = boundsOpts.outHeight
        val rotationDegrees = exifRotationDegrees(uri)
        // ② 算 inSampleSize(2 的幂,使解码宽度 ≤ targetWidth)。
        //    ⚠️ 用显示宽(旋转后)算,非原始位图宽:竖拍照片原始位图横躺
        //    (如 4096×3072 + orientation 90 → 显示 3072×4096),targetWidth
        //    对齐显示宽才能解出正确分辨率。
        //    ⚠️ 用 displayW/sampleSize > targetWidth(非 displayW/(sample*2) >= target):
        //    后者要求 displayW >= 2*target 才下采样,对 displayW≈target 的相机原图(3072 vs 2880)
        //    会得 sample=1 → 解全图 12MP + compress 大 JPEG + dart 再解一遍,比 readBytes 还慢。
        //    改成 > targetWidth:只要 displayW > target 就 sample≥2,解码宽度落到 (target/2, target]。
        //    例:displayW=3072, target=2880 → sample=2(解码 1536);displayW=4096 → sample=2(解码 2048)。
        val displayW = if (rotationDegrees == 90 || rotationDegrees == 270) origH else origW
        var sampleSize = 1
        while (displayW / sampleSize > safeTarget) {
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
        // ③' 应用 EXIF 旋转(见 readSampledImage doc):竖拍照片位图横躺,
        //    Matrix.postRotate 转正。翻转组合(TRANSPOSE/TRANSVERSE,多见于前置
        //    摄像头)忽略镜像只取旋转角——比横躺好,罕见场景不引入翻转复杂度。
        if (rotationDegrees == 0) return bitmap
        val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        bitmap.recycle()
        return rotated
    }

    // ──────────── 空闲预缓存（对标系统相册全相册 screenNail 预生成，配额内填满） ────────────

    /// 空闲预生成单张全图缓存：只落盘**不拷像素不跨 channel**（批量几千张时
    /// 省 n×4MB 的 channel 传输）。配额检查由调用方每 N 张调
    /// [fullCacheBytes] 自查（本方法不做整目录扫描）。
    ///
    /// [dateModifiedMs] 调用方已知的源图 DATE_MODIFIED（scanImages 结果里有），
    /// 传入可省去 exists 分支的一次单行查询——全库重扫时上千张 skip 各省
    /// 一次查询；null 则自查（单张调用路径不变）。
    ///
    /// @return 0=已生成 1=缓存已存在（校验有效）跳过 3=失败（源图缺失/损坏）
    fun precacheFullImage(id: String, targetWidth: Int, dateModifiedMs: Long? = null): Int {
        val safeTarget = targetWidth.coerceIn(960, 4096)
        val longId = id.toLongOrNull() ?: return 3
        // 已缓存（文件存在且 mtime 有效）→ 跳过（与 readFullCache 的校验一致，
        // 但不 decode——预生成只关心文件在不在）。
        val file = File(File(fullCacheDir, safeTarget.toString()), "$longId.jpg")
        if (file.exists()) {
            val dm = dateModifiedMs ?: queryDateModifiedMs(longId)
            if (dm == null || file.lastModified() >= dm) return 1
            file.delete() // 源图已编辑：删旧重生成
        }
        return try {
            val bitmap = decodeSampledBitmap(longId, safeTarget)
            writeFullCache(longId, safeTarget, bitmap)
            bitmap.recycle()
            0
        } catch (e: Exception) {
            Log.w(TAG, "precacheFullImage 失败 id=$id: ${e.message}")
            3
        }
    }

    /// 全图缓存目录当前字节数（配额满检测用）。
    /// 计数器制（2026-09 审查 M4）：调用高频（Worker 每 16 张配额检测、
    /// 设置页 3s 轮询、idle 预缓存），每次 walk 全目录 = 万级 stat 系统
    /// 调用。改为 AtomicLong 增量维护（写点 +len / 删点 -len），读时距
    /// 上次全量校准超过 [BYTES_CALIBRATE_MS] 才 walk 重算兜底——增量
    /// 漂移有界且自愈。-1 = 未初始化（首次读触发校准）。
    fun fullCacheBytes(): Long {
        calibrateFullBytes()
        return fullBytesCounter.get()
    }

    private fun calibrateFullBytes() {
        val now = SystemClock.elapsedRealtime()
        if (fullBytesCounter.get() >= 0 &&
            now - fullBytesCalibratedAt < BYTES_CALIBRATE_MS
        ) return
        val total = try {
            fullCacheDir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        } catch (_: Exception) {
            0L
        }
        fullBytesCounter.set(total)
        fullBytesCalibratedAt = SystemClock.elapsedRealtime()
    }

    private fun calibrateThumbBytes() {
        val now = SystemClock.elapsedRealtime()
        if (thumbBytesCounter.get() >= 0 &&
            now - thumbBytesCalibratedAt < BYTES_CALIBRATE_MS
        ) return
        val total = try {
            thumbnailCacheDir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        } catch (_: Exception) {
            0L
        }
        thumbBytesCounter.set(total)
        thumbBytesCalibratedAt = SystemClock.elapsedRealtime()
    }

    /// 已初始化时增量加（未初始化 -1 跳过，交由校准全量）。
    private fun AtomicLong.addIfReady(delta: Long) {
        if (get() >= 0) addAndGet(delta)
    }

    private val fullBytesCounter = AtomicLong(-1L)
    @Volatile private var fullBytesCalibratedAt = 0L
    private val thumbBytesCounter = AtomicLong(-1L)
    @Volatile private var thumbBytesCalibratedAt = 0L

    /// 设置全图缓存配额（用户拖档位）并立即收紧——缩档时按 LRU 删最旧到
    /// 新配额内。绕过 trim 节流（用户操作要求即时反馈）。
    /// 配额同步持久化到 SharedPreferences：WorkManager Worker 自建的
    /// Repository 实例与冷启动早期（Dart 推送到达前）都能拿到用户档位，
    /// 不再回落默认 128MB（曾致 Worker 新实例按默认配额提前停止/误 trim）。
    fun setFullCacheQuota(bytes: Long) {
        fullCacheQuotaBytes = bytes.coerceIn(64L * 1024 * 1024, 2L * 1024 * 1024 * 1024)
        quotaPrefs.edit().putLong(KEY_FULL_QUOTA_BYTES, fullCacheQuotaBytes).apply()
        lastFullTrimAt = 0 // 绕过节流
        trimFullCache()
    }

    /// 清空图片磁盘缓存。[clearThumb]=true 连缩略图缓存一起清（手动清理
    /// 按钮）；关闭预缓存开关只清全图缓存（full）。返回释放的字节数。
    fun clearImageCaches(clearThumb: Boolean): Map<String, Any> {
        var freedFull = 0L
        var freedThumb = 0L
        fun wipe(dir: File): Long {
            var freed = 0L
            val files = dir.walkTopDown().filter { it.isFile }.toList()
            for (f in files) {
                val len = f.length()
                if (f.delete()) freed += len
            }
            return freed
        }
        try {
            freedFull = wipe(fullCacheDir)
            fullBytesCounter.set(0L)
            fullBytesCalibratedAt = SystemClock.elapsedRealtime()
            if (clearThumb) {
                freedThumb = wipe(thumbnailCacheDir)
                thumbBytesCounter.set(0L)
                thumbBytesCalibratedAt = SystemClock.elapsedRealtime()
            }
        } catch (e: Exception) {
            Log.w(TAG, "clearImageCaches 失败: ${e.message}")
        }
        return mapOf("full" to freedFull, "thumb" to freedThumb)
    }

    /// 统计图片磁盘缓存占用（设置页显示）。thumb 两个目录分开报。
    /// 计数器制（见 [fullCacheBytes]）：读时校准，不再每次双目录 walk。
    fun imageCacheBytes(): Map<String, Any> {
        calibrateFullBytes()
        calibrateThumbBytes()
        return mapOf(
            "full" to fullBytesCounter.get(),
            "thumb" to thumbBytesCounter.get(),
        )
    }

    /// 当前配额（字节）。Worker / Dart 侧配额满检测用（与 [setFullCacheQuota]
    /// 同源的运行时值，已含 SP 恢复）。
    val fullCacheQuota: Long
        get() = fullCacheQuotaBytes

    /// 预缓存进度统计（设置页进度行数据源，一次查询全给齐）：
    ///   - cached：`visort_full/{targetWidth}` 目录的文件数（已缓存张数）
    ///   - total：全库（含回收站）、非 GIF 图片总数（应缓存目标）
    ///   - full/thumb：磁盘占用字节数（与 [imageCacheBytes] 同源）
    ///
    /// total 口径须与 cached 对齐——缓存目录里可以有回收站图的缓存
    /// （回收站视图也能浏览、触发 full 落盘，且移入回收站不删缓存），
    /// 若 total 排除回收站会出现「cached > total」（真机实证）。故显式
    /// MATCH_INCLUDE（显式声明跨 ROM 一致：AOSP 默认排除回收站，ColorOS
    /// 对 MANAGE_MEDIA app 默认包含——不能依赖默认）。GIF 仍排除：viewer
    /// GIF 走 readBytes 多帧路径，永远不写 full 盘缓存，cached 里不会有
    /// 它。手动彻底删除图片会同步删缓存文件（deleteImageCacheFiles），
    /// cached 随轮询即时反映。
    fun fullCacheStats(targetWidth: Int): Map<String, Any> {
        var cached = 0
        try {
            val dir = File(fullCacheDir, targetWidth.coerceIn(960, 4096).toString())
            cached = dir.listFiles()?.count { it.isFile } ?: 0
        } catch (_: Exception) {
        }
        val total = try {
            val bundle = android.os.Bundle().apply {
                putString(
                    android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,
                    "(${MediaStore.Images.Media.MIME_TYPE} IS NULL OR ${MediaStore.Images.Media.MIME_TYPE} != ?)",
                )
                putStringArray(
                    android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,
                    arrayOf("image/gif"),
                )
                putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
            }
            contentResolver.query(collection, arrayOf(MediaStore.Images.Media._ID), bundle, null)
                ?.use { it.count } ?: 0
        } catch (e: Exception) {
            Log.w(TAG, "fullCacheStats count 查询失败: ${e.message}")
            0
        }
        val bytes = imageCacheBytes()
        return mapOf(
            "cached" to cached,
            "total" to total,
            "full" to (bytes["full"] ?: 0L),
            "thumb" to (bytes["thumb"] ?: 0L),
        )
    }

    /// 删除图片后清其所有磁盘缓存文件（full 各宽度目录 + thumb 各尺寸目录，
    /// 按 `{id}.jpg` 精确匹配）。失败静默（残留文件由 LRU trim 最终回收）。
    fun deleteImageCacheFiles(longId: Long) {
        try {
            val name = "$longId.jpg"
            for (root in listOf(fullCacheDir, thumbnailCacheDir)) {
                val counter = if (root == fullCacheDir) fullBytesCounter else thumbBytesCounter
                root.listFiles()?.forEach { sub ->
                    sub.listFiles()?.forEach { f ->
                        if (f.name == name) {
                            // len 必须先取：delete 后 length() 恒 0。
                            val len = f.length()
                            if (f.delete()) counter.addIfReady(-len)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "deleteImageCacheFiles 失败: ${e.message}")
        }
    }

    // ──────────── viewer 全图磁盘缓存（screenNail 落盘，对标系统相册 MEMORY_AND_DISK） ────────────

    /// 全图缓存命中：读 JPEG → decodeByteArray → raw 像素（契约同 readSampledImage
    /// 返回值，dart 侧无感）。缓存 JPEG 已是「采样后+EXIF 转正」终态，无需再
    /// 采样/旋转。性能红线同 thumb 缓存：文件不存在（miss）零 DB 查询直接返回
    /// ——viewer 滚动高峰 miss 是常态；命中后一次 dm 查询可接受（此时确有
    /// 缓存文件，源图被编辑 dm 前进 → 删文件失效走原路径重解重写）。
    private fun readFullCache(id: Long, targetWidth: Int): Map<String, Any>? {
        val file = File(File(fullCacheDir, targetWidth.toString()), "$id.jpg")
        if (!file.exists()) return null // miss：零查询
        val dm = queryDateModifiedMs(id)
        if (dm != null && file.lastModified() < dm) {
            val len = file.length()
            if (file.delete()) fullBytesCounter.addIfReady(-len) // 源图已编辑：失效重解
            return null
        }
        return try {
            val bytes = file.readBytes()
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: return null
            val w = bitmap.width
            val h = bitmap.height
            val pixels = ByteArray(w * h * 4)
            bitmap.copyPixelsToBuffer(ByteBuffer.wrap(pixels))
            bitmap.recycle()
            mapOf("pixels" to pixels, "width" to w, "height" to h)
        } catch (e: Exception) {
            Log.w(TAG, "readFullCache 失败: ${e.message}")
            null
        }
    }

    /// 全图缓存轻量探测（viewer 快甩「盘缓存直通」前置门）：只查文件存在 +
    /// dm 失效，不读不解。校验逻辑与 [readFullCache] 完全对齐（存在 + mtime
    /// 校验），保证「探测命中 ⇒ 真读命中」——否则直通白发起一次请求。
    /// miss 零 DB 查询；命中付一次 dm 查询（快甩全命中场景 ~50 次，轻量）。
    /// 只读语义：失效文件留给真读路径删（此处删会与并发真读竞争）。
    fun fullCacheExists(id: String, targetWidth: Int): Boolean {
        val longId = id.toLongOrNull() ?: return false
        val safeTarget = targetWidth.coerceIn(960, 4096)
        val file = File(File(fullCacheDir, safeTarget.toString()), "$longId.jpg")
        if (!file.exists()) return false // miss：零查询
        val dm = queryDateModifiedMs(longId)
        return !(dm != null && file.lastModified() < dm)
    }

    /// 写全图缓存（compress 后立即落盘 + 节流 trim）。失败静默（不阻断解码
    /// 主路径）。
    private fun writeFullCache(id: Long, targetWidth: Int, bitmap: Bitmap) {
        try {
            val dir = File(fullCacheDir, targetWidth.toString())
            dir.mkdirs()
            val tmp = File(dir, "$id.tmp")
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            tmp.writeBytes(out.toByteArray())
            // 临时文件原子改名：trim/断电不留半写 JPEG（decodeByteArray 会
            // 当损坏图返回 null，命中变 miss 白付一次 IO）。
            val dest = File(dir, "$id.jpg")
            if (tmp.renameTo(dest)) {
                fullBytesCounter.addIfReady(dest.length())
            } else {
                tmp.delete()
            }
            trimFullCache()
        } catch (e: Exception) {
            Log.w(TAG, "writeFullCache 失败: ${e.message}")
        }
    }

    /// 全图缓存 trim（独立于缩略图缓存：独立目录/独立配额/独立节流）。
    /// 配额 [fullCacheQuotaBytes] 运行时可调（用户设置档位）；默认 128MB
    /// ≈ 850 张 1152 宽 JPEG（~150KB/张）。
    private fun trimFullCache() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFullTrimAt < TRIM_THROTTLE_MS) return
        lastFullTrimAt = now
        val quota = fullCacheQuotaBytes
        val files = fullCacheDir.walkTopDown().filter { it.isFile }.toList()
        var total = 0L
        for (f in files) total += f.length()
        if (total <= quota) return
        val sorted = files.sortedBy { it.lastModified() }
        for (f in sorted) {
            if (total <= quota) break
            val len = f.length()
            if (f.delete()) total -= len
        }
        fullBytesCounter.set(total)
        fullBytesCalibratedAt = SystemClock.elapsedRealtime()
    }

    /// 全图磁盘缓存目录（app cache，系统可清）。
    private val fullCacheDir: File by lazy {
        File(context.cacheDir, "visort_full").apply { mkdirs() }
    }

    /// 全图缓存最近一次 trim 时刻（ms）。
    private var lastFullTrimAt = 0L

    /// 全图缓存配额（字节，运行时可调——设置页档位手柄）。写路径
    /// （writeFullCache）与设置路径（setFullCacheQuota）均在 ioExecutor 或
    /// MethodChannel 线程，volatile 防可见性问题足够。
    /// 初值从 SharedPreferences 恢复（用户设过的档位），未设过用默认——
    /// Worker 新实例/冷启动早期与 plugin 实例看到同一配额。
    @Volatile
    private var fullCacheQuotaBytes: Long =
        context.getSharedPreferences("visort_cache", android.content.Context.MODE_PRIVATE)
            .getLong(KEY_FULL_QUOTA_BYTES, DEFAULT_FULL_CACHE_BYTES)

    /// 配额持久化（同上）。Worker 与 plugin 持不同 Repository 实例，共享此 SP。
    private val quotaPrefs =
        context.getSharedPreferences("visort_cache", android.content.Context.MODE_PRIVATE)

    /// 读 EXIF orientation 映射为旋转角(0/90/180/270)。
    /// PNG/WebP 无 orientation → 0;解析失败 → 0(横躺兜底,不崩)。
    private fun exifRotationDegrees(uri: Uri): Int {
        return try {
            val stream = contentResolver.openInputStream(uri) ?: return 0
            stream.use { s ->
                when (ExifInterface(s).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED
                )) {
                    ExifInterface.ORIENTATION_ROTATE_90,
                    ExifInterface.ORIENTATION_TRANSPOSE -> 90
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180
                    ExifInterface.ORIENTATION_ROTATE_270,
                    ExifInterface.ORIENTATION_TRANSVERSE -> 270
                    else -> 0
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "exifRotationDegrees 失败: ${e.message}")
            0
        }
    }

    /// HEIC 尺寸缓存：id → (dateModified, w, h)。分页/进桶重复扫描时免重复
    /// 流头读；文件被外部编辑（mtime 变）自动失效。进程内单写（ioExecutor
    /// 串行化 scan），ConcurrentHashMap 防并发写桶链损坏。
    private val heicSizeCache =
        java.util.concurrent.ConcurrentHashMap<String, Triple<Long, Int, Int>>()

    /// HEIC/HEIF 尺寸复核：inJustDecodeBounds 读容器真实尺寸。
    ///
    /// BitmapFactory 对 HEIF 读的是 ispe box 原始尺寸（不解析 irot 旋转 box），
    /// 而 MediaStore Q+ 的 WIDTH/HEIGHT 是旋转后显示尺寸——覆盖前按
    /// [orientation]（MediaStore ORIENTATION 列）交换宽高保持同语义。
    /// API<28 无 HEIF 解码支持/损坏/读失败返回 null，调用方保留 MediaStore 原值。
    private fun heicVerifiedSize(
        id: String, uri: Uri, orientation: Int, dateModified: Long
    ): Pair<Int, Int>? {
        // 缓存命中且 mtime 一致 → 免流头读（REPLACE 范围 mtime 不敏感：文件
        // 重写必然 mtime 前进；同 mtime 复写不翻尺寸的尾部编辑按稳定处理）。
        heicSizeCache[id]?.let { (m, w, h) ->
            if (m == dateModified) return w to h
        }
        val bounds: Pair<Int, Int> = try {
            val stream = contentResolver.openInputStream(uri) ?: return null
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            stream.use { s ->
                BitmapFactory.decodeStream(BufferedInputStream(s, 65536), null, opts)
            }
            if (opts.outWidth > 0 && opts.outHeight > 0) opts.outWidth to opts.outHeight else return null
        } catch (e: Exception) {
            Log.w(TAG, "heicVerifiedSize 失败: ${e.message}")
            return null
        }
        val rotated = if (orientation == 90 || orientation == 270) bounds.second to bounds.first else bounds
        heicSizeCache[id] = Triple(dateModified, rotated.first, rotated.second)
        return rotated
    }

    // ──────────── HDR 检测（JPEG Ultra HDR gainmap）────────────

    /// HDR 检测缓存：id → (dateModified, isHdr)。命中且 mtime 一致直接复用，
    /// 否则读文件头重测（aves (contentId, dateModified) 增量语义）。进程内有效；
    /// 冷启动每页首扫重测（60 张 × 64KB 流读 ≈ 数十 ms，分页加载路径可接受），
    /// 实测偏慢再加磁盘层——避免为一个 bool 提前引入 DB。
    // detectHdrs 在 ioExecutor（12 线程池）执行，Dart 侧 HDR 补测是
    // unawaited——快速切桶可让两轮补测并发。HashMap 并发写可致桶链
    // 损坏/脏读甚至卡死 IO 线程，必须用并发容器。
    private val hdrCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Long, Boolean>>()

    /// JPEG Ultra HDR 判定（网格 HDR 徽标数据源）。
    ///
    /// Ultra HDR（Android 14 官方格式）= 基础 JPEG + 末尾 MPF 辅图 gainmap +
    /// XMP `<hdrgm:Version>` 标识（aves XMP.hasHdrGainMap 同语义，其用
    /// metadata-extractor 解析 XMP 目录；此处拷头 64KB 直接字符串匹配，
    /// XMP APP1 段在文件头、短小，零依赖够用）。仅 JPEG；HEIC 的 gainmap
    /// 藏在 item property（需完整 ISO 14496 解析），不支持。
    private fun isHdrJpeg(uri: Uri): Boolean {
        return try {
            val stream = contentResolver.openInputStream(uri) ?: return false
            val head = ByteArray(65536)
            val n = stream.use { s ->
                var off = 0
                while (off < head.size) {
                    val r = s.read(head, off, head.size - off)
                    if (r < 0) break
                    off += r
                }
                off
            }
            val text = String(head, 0, n, Charsets.ISO_8859_1)
            text.contains("hdrgm:Version")
        } catch (e: Exception) {
            Log.w(TAG, "isHdrJpeg 失败: ${e.message}")
            false
        }
    }

    /// 带缓存的 HDR 检测入口。mime 门禁在先：非 JPEG（HEIC/PNG/WebP）不读
    /// 文件头（heic 的 gainmap 需完整 ISO 14496，isHdrJpeg 也不支持）——
    /// 直接 false，省一次 64KB 流读。
    private fun detectHdr(id: String, mime: String, dateModifiedMs: Long): Boolean {
        if (mime != "image/jpeg") return false
        hdrCache[id]?.let { (m, hdr) ->
            if (m == dateModifiedMs) return hdr
        }
        val longId = id.toLongOrNull() ?: return false
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        val hdr = isHdrJpeg(uri)
        hdrCache[id] = dateModifiedMs to hdr
        return hdr
    }

    /// 批量 HDR 检测（后台补测通道）：ids/mtimes 并行数组，返回同序布尔
    /// 列表。缓存命中零 IO；miss 读文件头并回写缓存。与 scanImages 分离
    /// ——网格数据先上屏，徽标数据到货后由 Dart 侧回填（aves cataloguing
    /// 同语义）。调用方须在后台线程执行（IO 密集）。
    fun detectHdrs(ids: List<String>, mtimes: List<Long>, mimes: List<String>): List<Boolean> {
        return ids.mapIndexed { i, id ->
            detectHdr(id, mimes.getOrElse(i) { "image/jpeg" }, mtimes.getOrElse(i) { 0L })
        }
    }

    // ──────────── 读取缩略图（相册网格用） ────────────

    /// 等比请求框长边上限：超长图（1080×20000 级）等比会放大出 300×5555
    /// 级 bitmap（~19MB），clamp 2048 防内存尖峰（系统 fit-inside 返回
    /// 等比更小值，aspect 不变）。
    private val tallImageMaxLongSide = 2048

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
    /// [squareCrop] 现仅参与 Dart 侧 ImageCache key（同档两种语义不混存），
    /// native 行为已无差异：一律【等比请求框】loadThumbnail（见函数内注释）。
    fun readThumbnail(
        id: String,
        width: Int = 256,
        height: Int = 256,
        dateModifiedMs: Long? = null,
        squareCrop: Boolean = false,
    ): ByteArray {
        val longId = id.toLongOrNull() ?: throw MsError.InvalidArg("非法图片 id: $id")

        // ① 等比缓存（{w}x{h}_iso，档级 key）命中 → 零解码直出。
        //    旧普通目录（{w}x{h}）整体废弃不读：方形请求框时代 ColorOS 的
        //    loadThumbnail 会直接吐系统 mini 缓存（384×512，固定 3:4/4:3）
        //    ——宽高比 ≠ 源图（真机实证：2304×4608 aspect 0.5 的图拿到
        //    346×461 = 3:4），错比例条目已被写盘固化，唯一安全做法是换目录。
        readThumbnailCache(longId, width, height, dateModifiedMs, crop = true)?.let { return it }

        // ② 源尺寸（一次 _ID 索引查询 ~0.1ms，仅在缓存 miss 后发生；命中
        //    路径保持零查询红线）→ 等比请求框。系统对【非方形】请求框按
        //    fit-inside 生成等比结果（长图路径已实证多年）；方形框则可能
        //    命中 mini 缓存吐 3:4（长图与本次 0.5 竖图双实证）。
        val srcSize = queryImageSize(longId)

        // ③ 小尺寸请求（占位层）优先 EXIF 内嵌缩略图（对标系统相册 fo0.java）：
        //    相机 JPEG 内嵌 160×120 缩略图，解码 ~1-5ms，免系统 loadThumbnail
        //    服务首次生成的 50~200ms —— 首屏占位秒显的关键。
        //    内嵌缩略图天然等比（全图等比缩小），无 mini 污染问题。
        //    无 EXIF 时回退 loadThumbnail（小尺寸采样少，也快于大尺寸）。
        if (width <= EXIF_THUMBNAIL_MAX_SIZE && height <= EXIF_THUMBNAIL_MAX_SIZE) {
            exifThumbnail(longId)?.let { bytes ->
                writeThumbnailCache(longId, width, height, dateModifiedMs, bytes, crop = true)
                return bytes
            }
        }

        // ④ 等比请求框构造（tall 路径泛化）：短边 = min(target, 源短边)，
        //    长边等比放大但不超源长边与 [tallImageMaxLongSide] → 系统
        //    fit-inside 返回等比结果。
        //    ⚠️ 源尺寸查询失败（binder 繁忙/行不存在）或 WIDTH/HEIGHT=0
        //    （损坏/未完成扫描）时【不回落方形框】：方形框正是 ColorOS mini
        //    污染（固定 3:4）的触发条件，且无 srcAspect 无从校验——直接走
        //    decodeFullFallback 等比自解（读不出尺寸的损坏图由其 throw，
        //    Dart 侧 readBytes 兜底，链路闭环）。
        val (srcW, srcH) = srcSize ?: (null to null)
        if (srcW == null || srcH == null || srcW <= 0 || srcH <= 0) {
            return decodeFullFallback(longId, id, width, height, dateModifiedMs)
        }
        val srcShort = min(srcW, srcH)
        val srcLong = max(srcW, srcH)
        val reqShort = max(1, min(min(width, height), srcShort))
        val reqLong = min(
            min((reqShort.toLong() * srcLong / srcShort).toInt(), srcLong),
            tallImageMaxLongSide,
        )
        val reqW: Int
        val reqH: Int
        if (srcW < srcH) {
            reqW = reqShort
            reqH = reqLong
        } else {
            reqW = reqLong
            reqH = reqShort
        }

        // ⑤ loadThumbnail + 编码。信号量限制并发：首屏 20+ 张同时
        //    压系统 MediaStore 缩略图服务会造成 CPU 尖峰与排队抖动。
        val bitmap: Bitmap
        thumbnailSemaphore.acquire()
        try {
            val uri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
            )
            bitmap = try {
                contentResolver.loadThumbnail(uri, Size(reqW, reqH), null)
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
        // 等比结果校验：系统偶发仍吐非等比（如命中 mini）时丢结果不落盘，
        // 退回源尺寸等比自解（decode 兜底）——防止污染固化。
        val reqAspect = reqW.toDouble() / reqH.toDouble()
        val gotAspect = bitmap.width.toDouble() / bitmap.height.toDouble()
        val srcAspect = srcW.toDouble() / srcH.toDouble()
        val aspectErr = abs(gotAspect / srcAspect - 1.0)
        val reqErr = abs(reqAspect / srcAspect - 1.0)
        if (aspectErr <= max(0.02, reqErr)) {
            writeThumbnailCache(longId, width, height, dateModifiedMs, bytes, crop = true)
            return bytes
        }
        Log.d(
            TAG,
            "readThumbnail: 等比校验拒绝 id=$id src=${srcW}x${srcH} " +
                "req=${reqW}x${reqH} got=${bitmap.width}x${bitmap.height}",
        )
        return decodeFullFallback(longId, id, width, height, dateModifiedMs)
    }

    /// 等比校验失败后的兜底：流式解码原图 + EXIF 旋转 + 等比缩放（绕开
    /// loadThumbnail 的 mini 污染）。仅校验拒绝时触发（罕见路径）。
    private fun decodeFullFallback(
        longId: Long,
        id: String,
        width: Int,
        height: Int,
        dateModifiedMs: Long?,
    ): ByteArray {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        // 原始位图尺寸（未旋转）+ EXIF 角度 → 显示尺寸
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val bStream = contentResolver.openInputStream(uri)
            ?: throw MsError.QueryFailed("无法打开 InputStream: $id")
        bStream.use {
            BitmapFactory.decodeStream(BufferedInputStream(it, 65536), null, boundsOpts)
        }
        val origW = boundsOpts.outWidth
        val origH = boundsOpts.outHeight
        if (origW <= 0 || origH <= 0) {
            throw MsError.QueryFailed("decodeFullFallback: 无法读尺寸 id=$id")
        }
        val rotation = exifRotationDegrees(uri)
        val dispW = if (rotation == 90 || rotation == 270) origH else origW
        val dispH = if (rotation == 90 || rotation == 270) origW else origH
        // inSampleSize 先粗下采样（2 的幂，短边解到 ~(target/2, target]）
        var sampleSize = 1
        while (min(dispW, dispH) / sampleSize > min(width, height)) {
            sampleSize *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val dStream = contentResolver.openInputStream(uri)
            ?: throw MsError.QueryFailed("无法打开 InputStream: $id")
        var bitmap = dStream.use {
            BitmapFactory.decodeStream(BufferedInputStream(it, 65536), null, opts)
        } ?: throw MsError.QueryFailed("无法解码 id=$id")
        if (rotation != 0) {
            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            bitmap.recycle()
            bitmap = rotated
        }
        // 精确等比缩到短边 = min(target, 源短边)
        val targetShort = min(min(width, height), min(bitmap.width, bitmap.height))
        if (min(bitmap.width, bitmap.height) != targetShort) {
            val scale = targetShort.toDouble() / min(bitmap.width, bitmap.height).toDouble()
            val scaled = Bitmap.createScaledBitmap(
                bitmap,
                max(1, (bitmap.width * scale).roundToInt()),
                max(1, (bitmap.height * scale).roundToInt()),
                true,
            )
            bitmap.recycle()
            bitmap = scaled
        }
        val baos = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        val outW = bitmap.width
        val outH = bitmap.height
        bitmap.recycle()
        val out = baos.toByteArray()
        writeThumbnailCache(longId, width, height, dateModifiedMs, out, crop = true)
        Log.d(
            TAG,
            "readThumbnail: 等比兜底 id=$id ${dispW}x${dispH} -> ${outW}x${outH} ${out.size}B",
        )
        return out
    }

    /// 查单图源尺寸（WIDTH/HEIGHT 列，_ID 索引查询）。失败返回 null。
    private fun queryImageSize(id: Long): Pair<Int, Int>? {
        return try {
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT),
                "${MediaStore.Images.Media._ID}=?",
                arrayOf(id.toString()),
                null,
            )?.use { c -> if (c.moveToFirst()) c.getInt(0) to c.getInt(1) else null }
        } catch (e: Exception) {
            null
        }
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

    /// 命中条件：文件存在 && 文件 mtime（=写入时间）≥ 源图 DATE_MODIFIED。
    /// 写缓存时 mtime 保持【写入时间】（不 setLastModified 源时间）——这是
    /// 关键：① 命中校验仍正确（外部编辑后源 dm 前进 > 写入时间 → miss 重解；
    ///    时钟一致下编辑时刻必然晚于缓存写入时刻）；② trim 按 mtime 排序
    ///    拿到真实「写入即 LRU」顺序（旧方案 mtime=源时间，老照片刚写入的
    ///    缓存被当最旧先删——写删循环、缓存形同虚设）。
    /// 性能红线（拖拽/滑动回归根因）：文件不存在（miss）时【零 DB 查询】
    /// 直接返回——miss 在滚动高峰是常态，每张一次 contentResolver 单行
    /// 查询会把缩略图加载拖慢一个数量级。
    private fun readThumbnailCache(
        id: Long,
        width: Int,
        height: Int,
        dateModifiedMs: Long?,
        crop: Boolean = false,
    ): ByteArray? {
        val dirName = if (crop) "${width}x${height}_iso" else "${width}x$height"
        val file = File(File(thumbnailCacheDir, dirName), "$id.jpg")
        if (!file.exists()) return null // miss：零查询
        // 命中再自查源图 dm（此时文件确实存在，一次查询可接受；调用方传
        // 值时省查询）
        val dm = dateModifiedMs ?: queryDateModifiedMs(id)
        if (dm == null || file.lastModified() >= dm) {
            return try { file.readBytes() } catch (e: Exception) { null }
        }
        val len = file.length()
        if (file.delete()) thumbBytesCounter.addIfReady(-len) // 源图已编辑：失效重解
        return null
    }

    /// 查单图 DATE_MODIFIED（毫秒）；查询失败/无值返回 null（不阻断缓存命中）。
    private fun queryDateModifiedMs(id: Long): Long? {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
        )
        return try {
            contentResolver.query(
                uri, arrayOf(MediaStore.Images.Media.DATE_MODIFIED), null, null, null
            )?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) * 1000 else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun writeThumbnailCache(
        id: Long,
        width: Int,
        height: Int,
        dateModifiedMs: Long?,
        bytes: ByteArray,
        crop: Boolean = false,
    ) {
        try {
            val dirName = if (crop) "${width}x${height}_iso" else "${width}x$height"
            val dir = File(thumbnailCacheDir, dirName)
            dir.mkdirs()
            // 单格式 ${id}.jpg；writeBytes 的 mtime=写入时间（trim LRU 正确，
            // 命中校验见 readThumbnailCache）。不查 DB：写路径在滚动高峰是
            // miss 主出口，每张一次 contentResolver 查询放大 IO 延迟。
            val file = File(dir, "$id.jpg")
            // 计数器：覆盖写先减旧文件长度（同 id 同尺寸重写，罕见）。
            if (file.exists()) thumbBytesCounter.addIfReady(-file.length())
            file.writeBytes(bytes)
            thumbBytesCounter.addIfReady(file.length())
            trimThumbnailCache()
        } catch (e: Exception) {
            Log.w(TAG, "writeThumbnailCache 失败: ${e.message}")
        }
    }

    /// 最近一次 trim 全目录扫描时刻（ms）。拖拽/滑动高峰每次写缓存都触发
    /// walkTopDown 是 O(缓存文件数) 全目录遍历——几千文件下每写一张扫一遍
    /// 直接拖慢滚动。节流：高峰最多 5s 一次（超限清理只延时最多 5s）。
    private var lastTrimAt = 0L

    /// 容量上限：超出按 mtime 删最旧，直到达标。目录小（≤128MB）时跳过扫描。
    private fun trimThumbnailCache() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastTrimAt < TRIM_THROTTLE_MS) return
        lastTrimAt = now
        // 缩略图实际写入 ${width}x${height}/ 子目录——顶层 listFiles 只见
        // 目录（isFile 过滤后为空、total 恒 0），旧实现永不触发清理、
        // 缓存无界增长。walkTopDown 递归统计并按最旧逐个淘汰。
        val files = thumbnailCacheDir.walkTopDown().filter { it.isFile }.toList()
        var total = 0L
        for (f in files) total += f.length()
        if (total <= MAX_THUMBNAIL_CACHE_BYTES) return
        val sorted = files.sortedBy { it.lastModified() }
        for (f in sorted) {
            if (total <= MAX_THUMBNAIL_CACHE_BYTES) break
            val len = f.length()
            if (f.delete()) total -= len
        }
        // trim 本身就是全量 walk：顺带校准计数器。
        thumbBytesCounter.set(total)
        thumbBytesCalibratedAt = SystemClock.elapsedRealtime()
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

        /// viewer 全图磁盘缓存默认配额（128MB ≈ 850 张 1152 宽 JPEG，
        /// ~150KB/张——对标系统相册 screenNail 磁盘层）。运行时由
        /// setFullCacheQuota 按用户档位（256MB~2GB）调整。
        private const val DEFAULT_FULL_CACHE_BYTES = 128L * 1024 * 1024

        /// 配额持久化 SP 键（文件 "visort_cache"，见 quotaPrefs）。
        const val KEY_FULL_QUOTA_BYTES = "full_quota_bytes"

        /// trim 全目录扫描最小间隔（ms）：写缓存高峰不每次触发 walkTopDown。
        private const val TRIM_THROTTLE_MS = 5000L

        /// 字节计数器全量校准间隔（ms）：增量计数漂移有界自愈；间隔内的
        /// 读请求全部走计数器（高频配额检测/轮询不再触发目录 walk）。
        private const val BYTES_CALIBRATE_MS = 30_000L

        /// EXIF 内嵌缩略图适用的最大请求尺寸（px）：≤128 的占位层请求
        /// 优先走 EXIF（~5ms），更大请求直接 loadThumbnail（EXIF 图糊）。
        private const val EXIF_THUMBNAIL_MAX_SIZE = 128
    }

    // ──────────── 批量删除（Recovery API） ────────────

    /// 构造批量删除请求（createDeleteRequest，一次系统弹窗）。
    /// MANAGE_MEDIA 已授权时先逐 URI 直删（零弹窗），全量成功返回 Done(实际数)；
    /// 需弹窗返回 NeedsConsent。Done 必须携带真实删除数——此前协议把
    /// 「已直删完成」误报为 0，Dart 侧把已删文件记为 delete_failed。
    fun createDeleteRequest(ids: List<String>): DeleteResult {
        if (ids.isEmpty()) return DeleteResult.Done(0)
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        if (uris.isEmpty()) return DeleteResult.Done(0)

        // MANAGE_MEDIA 已授权 → 尝试直接逐个删除（零弹窗）。
        // 注意：部分 ROM（如 ColorOS）即使 AppOps 报告 mode=ALLOWED，实际 contentResolver.delete
        // 仍会抛 "has no access" 异常。故删除失败的 URI 必须 fallback 到系统弹窗，否则会
        // 误报成功（Done 全量 → Dart 以为删了，实际文件还在）。
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
            if (failed.isEmpty()) return DeleteResult.Done(deleted)
            // alreadyDeleted 携带直删数：取消弹窗时上层据此如实上报部分成功
            return DeleteResult.NeedsConsent(systemDeleteRequest(failed), deleted)
        }

        return DeleteResult.NeedsConsent(systemDeleteRequest(uris))
    }

    /// 删除结果：Done=已直接完成（含实际删除数）；NeedsConsent=需系统弹窗。
    /// [alreadyDeleted]=发起弹窗前 MANAGE_MEDIA 直删成功的数量。用户取消
    /// 弹窗时这部分**已物理删除**——上层必须拿到该数（取消但已删>0 时
    /// 上报成功数而非 CANCELLED），否则本地列表残留幽灵条目、结果误报。
    sealed class DeleteResult {
        data class Done(val deleted: Int) : DeleteResult()
        data class NeedsConsent(
            val intentSender: IntentSender,
            val alreadyDeleted: Int = 0
        ) : DeleteResult()
    }

    /// 构造系统级删除弹窗（createDeleteRequest，批量一次弹窗）。
    /// 抽出以便 MANAGE_MEDIA 路径删除失败时复用 fallback。
    private fun systemDeleteRequest(uris: List<Uri>): IntentSender {
        Log.i(TAG, "systemDeleteRequest: createDeleteRequest, uris=${uris.size}")
        return MediaStore.createDeleteRequest(contentResolver, uris).intentSender
    }

    // ──────────── 存在性检查 ────────────

    fun exists(id: String): Boolean {
        val uri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toLongOrNull() ?: -1L
        )
        // 查询失败上抛而非吞成 false：exists 的消费方（删除/恢复复查）把
        // false 当"已删除/未恢复"——查询失败被当删除证据会导致本地列表
        // 误移除（破坏性方向）。Plugin 层转 error，Dart 按三态保守处理。
        return try {
            contentResolver.query(
                uri, arrayOf(MediaStore.Images.Media._ID), null, null, null
            )?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            Log.w(TAG, "exists 查询失败 id=$id: ${e.message}")
            throw e
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
    /// 移动结果：直接完成时返回**实际成功移动的 id 集**（部分成功不再被
    /// 上层误报为全失败——旧协议只回成功数，count != total 时 Dart 全记
    /// move_failed，但其中自有文件早已物理移走）。
    sealed class MoveResult {
        data class Done(val movedIds: List<String>) : MoveResult()
        /// [alreadyMoved]=发起弹窗前已直移成功的自有文件 id 集。
        /// 用户取消弹窗时这些文件**已经物理移走**——上层必须拿到该子集
        /// 才能如实报部分成功；丢失会让本地状态与磁盘脱节（丢已移动状态）。
        data class NeedsConsent(
            val intentSender: IntentSender,
            val alreadyMoved: List<String> = emptyList()
        ) : MoveResult()
    }

    fun moveToRelativePath(ids: List<String>, relativePath: String): MoveResult {
        if (ids.isEmpty() || relativePath.isEmpty()) return MoveResult.Done(emptyList())


        // 先尝试直接逐个 update（自有文件直接成功，无需授权）
        val moved = doMoveToRelativePath(ids, relativePath)
        if (moved.size == ids.size) {
            Log.i(TAG, "moveToRelativePath 全部直接成功: ${moved.size}/${ids.size} → $relativePath")
            return MoveResult.Done(moved)
        }

        // 部分或全部失败（其他 app 的文件需授权）
        val remaining = ids.size - moved.size
        Log.i(TAG, "moveToRelativePath 部分失败 ${moved.size}/${ids.size}（$remaining 张需授权）")

        // MANAGE_MEDIA 已授权 → createWriteRequest 免弹窗直接通过，授权后重新 doMove
        if (hasManageMediaPermission()) {
            val uris = ids.mapNotNull { id ->
                val longId = id.toLongOrNull() ?: return@mapNotNull null
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
            }
            return try {
                // createWriteRequest 在 MANAGE_MEDIA 授权下不弹窗，返回的 PendingIntent 直接启动。
                // alreadyMoved 携带第一轮直移子集：取消时上层据此报部分成功。
                val intentSender = MediaStore.createWriteRequest(contentResolver, uris).intentSender
                MoveResult.NeedsConsent(intentSender, moved)
            } catch (e: Exception) {
                Log.w(TAG, "moveToRelativePath createWriteRequest 异常: ${e.message}")
                MoveResult.Done(moved)
            }
        }

        // 无 MANAGE_MEDIA → createWriteRequest 会弹窗
        return try {
            val sender = buildWriteRequest(ids)
            if (sender != null) MoveResult.NeedsConsent(sender, moved) else MoveResult.Done(moved)
        } catch (e: Exception) {
            Log.w(TAG, "moveToRelativePath buildWriteRequest 异常: ${e.message}")
            MoveResult.Done(moved)
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

    /// 真正执行 RELATIVE_PATH update。返回成功更新的 id 集（部分成功如实
    /// 上报，调用方据此把「已直接移走的自有文件」与「待授权/失败」分开计）。
    /// 授权通过后必须调用此方法才能真移动。
    ///
    /// 重要：Android 10+ 不允许对 EXTERNAL_CONTENT_URI（集合）批量 update，
    /// 必须对每个图片的单独 content URI（content://media/external/images/media/<id>）逐个 update。
    fun doMoveToRelativePath(ids: List<String>, relativePath: String): List<String> {
        if (ids.isEmpty() || relativePath.isEmpty()) return emptyList()

        val normalizedPath = if (relativePath.endsWith("/")) relativePath else "$relativePath/"
        val moved = mutableListOf<String>()
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
                // 排除回收站项：trashed 行的路径属于系统回收站的恢复映射
                //（untrash 恒回到 trash 时刻路径）。对它改 RELATIVE_PATH 会把行
                // 移成病态——恢复通道从此失效（真机实证：恢复弹窗确认后
                // is_trashed 仍=1，照片静默消失）。selection 过滤后 trashed 行
                // 返回 0 rows，自然不计入 moved（上层如实记 move_failed）。
                val rows = contentResolver.update(
                    itemUri, cv, "${MediaStore.Images.Media.IS_TRASHED} = 0", null
                )
                if (rows > 0) moved.add(id)
                Log.i(TAG, "doMoveToRelativePath item $id: $rows 行 → $normalizedPath")
            } catch (e: Exception) {
                Log.w(TAG, "doMoveToRelativePath item $id 异常: ${e.message}")
            }
        }
        Log.i(TAG, "doMoveToRelativePath 完成: ${moved.size}/${ids.size} → $normalizedPath")
        return moved
    }

    // ──────────── 重命名（改 DISPLAY_NAME）────────────

    /// 同目录下是否已存在同名文件（大小写不敏感，排除自身，排除回收站项——
    /// 默认 query 不含 trashed）。重命名预检用（aves rename dialog 同款校验）。
    fun nameExistsInDir(id: String, newName: String): Boolean {
        val longId = id.toLongOrNull() ?: return false
        val srcUri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        // 源文件所在目录（RELATIVE_PATH）
        val relPath = try {
            contentResolver.query(
                srcUri, arrayOf(MediaStore.Images.Media.RELATIVE_PATH), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: Exception) {
            Log.w(TAG, "nameExistsInDir 查目录异常: ${e.message}"); null
        } ?: return false
        val selection =
            "${MediaStore.Images.Media.RELATIVE_PATH} = ? AND LOWER(${MediaStore.Images.Media.DISPLAY_NAME}) = ? AND ${MediaStore.Images.Media._ID} != ?"
        return try {
            contentResolver.query(
                collection,
                arrayOf(MediaStore.Images.Media._ID),
                selection,
                arrayOf(relPath, newName.lowercase(), longId.toString()),
                null
            )?.use { it.count > 0 } ?: false
        } catch (e: Exception) {
            Log.w(TAG, "nameExistsInDir 查同名异常: ${e.message}")
            false
        }
    }

    /// 单张重命名（update DISPLAY_NAME，MediaStore 自动同步重命名底层文件，
    /// _ID 不变 → Dart 侧 uri/缓存仍有效，仅 name 变化）。
    /// 与 moveToRelativePath 同款 Done/NeedsConsent 双分支：自有文件直接
    /// update 成功；他人文件走 createWriteRequest 授权后重试。
    fun renameTo(id: String, newName: String): MoveResult {
        if (id.isEmpty() || newName.isEmpty()) return MoveResult.Done(emptyList())
        val longId = id.toLongOrNull() ?: return MoveResult.Done(emptyList())
        val itemUri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        val doUpdate = {
            try {
                val cv = android.content.ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, newName)
                }
                if (contentResolver.update(itemUri, cv, null, null) > 0) 1 else 0
            } catch (e: Exception) {
                Log.w(TAG, "renameTo update 异常: ${e.message}"); 0
            }
        }
        val success = doUpdate()
        if (success > 0) {
            Log.i(TAG, "renameTo 直接成功: $id → $newName")
            return MoveResult.Done(listOf(id))
        }
        // 他人文件 → createWriteRequest 授权（MANAGE_MEDIA 下免弹窗直通）
        return try {
            val sender = buildWriteRequest(listOf(id))
            if (sender != null) MoveResult.NeedsConsent(sender) else MoveResult.Done(emptyList())
        } catch (e: Exception) {
            Log.w(TAG, "renameTo buildWriteRequest 异常: ${e.message}")
            MoveResult.Done(emptyList())
        }
    }

    /// 授权通过后真正执行重命名（onActivityResult 回调里重试）。返回 1 成功。
    fun doRename(id: String, newName: String): Int {
        val longId = id.toLongOrNull() ?: return 0
        val itemUri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
        )
        return try {
            val cv = android.content.ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, newName)
            }
            val rows = contentResolver.update(itemUri, cv, null, null)
            Log.i(TAG, "doRename item $id: $rows 行 → $newName")
            if (rows > 0) 1 else 0
        } catch (e: Exception) {
            Log.w(TAG, "doRename item $id 异常: ${e.message}")
            0
        }
    }

    // ──────────── 复制到相册（insert 新条目 + 流拷贝）────────────

    /// 批量复制到指定 RELATIVE_PATH。返回成功数。
    /// 权限模型与 move 不同：读源（READ_MEDIA_IMAGES 已覆盖全部图）+ 写自己
    /// insert 的新条目（owner 是本 app）→ 无需授权弹窗。
    /// 同名冲突：MediaStore insert 自动加 " (1)" 后缀（aves RENAME 冲突策略）。
    /// 新条目 DATE_ADDED 为当前时间（copy 语义即新文件）。
    fun copyToRelativePath(ids: List<String>, relativePath: String): Int {
        if (ids.isEmpty() || relativePath.isEmpty()) return 0

        val normalizedPath = if (relativePath.endsWith("/")) relativePath else "$relativePath/"
        var success = 0
        for (id in ids) {
            val longId = id.toLongOrNull() ?: continue
            val srcUri = ContentUris.withAppendedId(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId
            )
            var dstUri: Uri? = null
            var published = false
            try {
                // 源元数据（DISPLAY_NAME / MIME_TYPE）
                val src = contentResolver.query(
                    srcUri,
                    arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE),
                    null, null, null
                )?.use { c ->
                    if (c.moveToFirst()) (c.getString(0) ?: "") to (c.getString(1) ?: "image/jpeg") else null
                } ?: continue
                val (srcName, srcMime) = src
                if (srcName.isEmpty()) continue
                val values = android.content.ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, srcName)
                    put(MediaStore.Images.Media.MIME_TYPE, srcMime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, normalizedPath)
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                dstUri = contentResolver.insert(collection, values) ?: continue
                var copied = false
                contentResolver.openInputStream(srcUri)?.use { input ->
                    contentResolver.openOutputStream(dstUri)?.use { output ->
                        input.copyTo(output)
                        copied = true
                    }
                }
                if (copied) {
                    // 发布条目（IS_PENDING=0 后 MediaStore 扫描入库、进相册）
                    val done = android.content.ContentValues().apply {
                        put(MediaStore.Images.Media.IS_PENDING, 0)
                    }
                    contentResolver.update(dstUri, done, null, null)
                    published = true
                    success++
                }
            } catch (e: Exception) {
                Log.w(TAG, "copyToRelativePath item $id 异常: ${e.message}")
            } finally {
                // 已 insert 但未成功发布的 pending 占位条目必须清理——
                // 孤儿 IS_PENDING=1 条目对默认查询不可见但占 MediaStore 行
                //（旧代码仅拷贝失败路径清理，openInputStream/update 抛异常
                // 的路径漏删，泄漏不可见残尸条目）。
                if (dstUri != null && !published) {
                    try {
                        contentResolver.delete(dstUri, null, null)
                    } catch (e: Exception) {
                        Log.w(TAG, "copyToRelativePath 清理 pending 条目失败: ${e.message}")
                    }
                }
            }
        }
        Log.i(TAG, "copyToRelativePath 完成: $success/${ids.size} → $normalizedPath")
        return success
    }

    /// 构造批量写授权请求的 IntentSender。
    /// minSdk 30（Android 11+）下 MediaStore.createWriteRequest 恒可用（最
    /// 可靠路径——旧「update 试探 SecurityException 拿授权」的方案已随
    /// minSdk 26→30 迁移删除）。授权通过后 Plugin 重新调 doMoveToRelativePath
    /// 执行移动/重命名。
    @Throws(Exception::class)
    private fun buildWriteRequest(ids: List<String>): IntentSender? {
        // 先构造 URI 列表
        val uris = ids.mapNotNull { id ->
            val longId = id.toLongOrNull() ?: return@mapNotNull null
            ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, longId)
        }
        if (uris.isEmpty()) return null

        // createWriteRequest 获取批量写权限（minSdk 30 恒可用，最可靠）
        return MediaStore.createWriteRequest(contentResolver, uris).intentSender
    }
}
