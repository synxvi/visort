package com.synxvi.visort.mediastore

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

// ───────────────────────── 全库预缓存 Worker（WorkManager 约束调度） ─────────────────────────
//
// 与前台 idle_precache（Dart 会话）分工：
//   - Worker：全库首轮批量补齐。约束「存储不低」（2026-08-29 用户定调
//     去掉充电限制——排队后系统给窗口即跑，~1900 张单线程解码约 10~15
//     分钟），不要求 app 前台、跨进程/设备重启由 WorkManager 持久化调度
//     续跑。这是主流做法（对标官方对「可延迟但必须可靠完成」的批量工作
//     的定位），替代此前「绑定 app 前台 + 管线空闲」导致 8 小时仅爬 63%
//     的模式。
//   - 前台 idle 会话：保留，管日常增量（新照片在 DATE_ADDED 倒序头部，
//     会话开头即处理）。
//
// 与前台会话并发：precacheFullImage 幂等（已存在返回 1）+ writeFullCache
// 临时文件原子改名，重复执行无害，仅浪费一次解码（充电时前台用 app 的
// 窗口小，不值得跨端互斥）。
//
// 配额：Worker 自建 MediaStoreRepository 实例——配额已持久化到
// SharedPreferences（见 quotaPrefs），三处（plugin 实例 / Worker 实例 /
// 冷启动早期）读到同一用户档位，不回落默认 128MB。

/// 全库预缓存任务体。targetWidth 由 enqueue 方传入（与 Dart
/// computeViewerTargetWidth 同源）；缺省时用屏幕物理宽自算兜底。
class PrecacheWorker(appContext: Context, params: WorkerParameters) :
    Worker(appContext, params) {

    override fun doWork(): Result {
        val tw = inputData.getInt(KEY_TARGET_WIDTH, 0).takeIf { it > 0 }
            ?: fallbackTargetWidth()
        val repo = MediaStoreRepository(applicationContext)
        var cursor: String? = null
        var generated = 0
        var skipped = 0
        var quotaFull = false
        try {
            while (true) {
                // isStopped：约束失效（存储低）/开关关闭触发的系统 stop——
                // 尽快返回让出资源；约束式任务由 WorkManager 自动重新入队
                // 等待下次窗口，无需自行 retry。
                if (isStopped) return Result.success()
                val page = repo.scanImages(emptyList(), afterCursor = cursor, limit = PAGE)
                if (page.images.isEmpty()) break
                for (info in page.images) {
                    if (isStopped) return Result.success()
                    // GIF 跳过：viewer GIF 走 readBytes 多帧，不读 full 盘缓存
                    //（与 idle 会话同规则）。
                    if (info.mime == "image/gif") continue
                    val code = runCatching {
                        repo.precacheFullImage(info.id, tw, info.dateModifiedMs)
                    }.getOrDefault(3)
                    if (code == 0) generated++ else if (code == 1) skipped++
                    // 每 16 张查配额（walkTopDown 有成本）：写满即收工。
                    // 0.95 阈值 + skip 段也查（无 generated>0 门槛）——配额
                    // 装不下全库时，被 trim 挤掉的老图重解码写回再挤掉 =
                    // 写-删拉锯（重解码纯浪费）；skip 段自查在重写开始前
                    // 即发现已满整轮停止（与 Dart idle 会话同修，真机实证）。
                    if ((generated + skipped) % QUOTA_CHECK_EVERY == 0 &&
                        repo.fullCacheBytes() >= repo.fullCacheQuota * 95 / 100
                    ) {
                        quotaFull = true
                        break
                    }
                }
                if (quotaFull) break
                cursor = page.nextCursor ?: break // 全库扫完
            }
        } catch (e: Exception) {
            // scanImages 上抛（binder 繁忙等瞬时故障）→ retry（指数退避），
            // 已落盘的进度不会丢（下次 skip 快速越过）。
            Log.w(TAG, "PrecacheWorker 异常: ${e.message}")
            return Result.retry()
        }
        Log.i(
            TAG,
            "PrecacheWorker 完成 gen=$generated skip=$skipped " +
                "quotaFull=$quotaFull tw=$tw",
        )
        return Result.success()
    }

    /// tw 兜底：max(960, 屏幕物理宽 × 0.8)，与 Dart computeViewerTargetWidth
    /// 同公式（app 后台无 Flutter view，用 WindowMetrics 物理边界——
    /// maximumWindowMetrics 为全屏边界，与 Flutter physicalSize 同义）。
    private fun fallbackTargetWidth(): Int {
        // Worker 不是 ContextWrapper 本体，systemService 经 applicationContext 取。
        val wm = applicationContext.getSystemService(Context.WINDOW_SERVICE)
            as? android.view.WindowManager
        val w = wm?.maximumWindowMetrics?.bounds?.width() ?: 1080
        return (w * 0.8).toInt().coerceAtLeast(960)
    }

    companion object {
        /// 唯一任务名（enqueueUniqueWork KEEP——重复 enqueue 不叠加）。
        const val UNIQUE_NAME = "visort_precache_full"

        /// inputData 键：目标解码宽度（物理像素）。
        const val KEY_TARGET_WIDTH = "targetWidth"

        private const val PAGE = 200
        private const val QUOTA_CHECK_EVERY = 16
        private const val TAG = "PrecacheWorker"
    }
}
