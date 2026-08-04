# 图片解码管线:对标系统相册的优化记录

> 记录 sortr 安卓 viewer 图片解码优化的调研与实施。逆向对标:一加 13 系统相册 `com.coloros.gallery3d`。

## 1. 背景

sortr viewer 打开图片有 250ms 缩放(飞行)动画。若解码在动画期内没完成,viewer 显现后会继续垫 300px 模糊缩略图直到清晰图就绪——表现为「模糊全屏帧很久」。目标:让清晰图在动画结束瞬间就位。

## 2. 系统相册解码逆向(对标基准)

反编译产物:`_reverse/gallery3d/`(`jadx_src/` java + `apktool_full/` smali + `ANALYSIS.md`)。

### 2.1 三条解码路径(都不经 JPEG 中转)

| 路径 | 用途 | 实现 | 依据 |
|---|---|---|---|
| A. Glide Downsampler | 列表/网格/缩略图 | BitmapFactory + inSampleSize,默认 CENTER_OUTSIDE,inBitmap 池复用 | `jadx_src/classes6/.../glide/load/resource/bitmap/a.java`(Downsampler)、`DownsampleStrategy.java` |
| B. oplus CodecHelper | 全屏查看器整图 | BitmapFactory + inSampleSize(像素上限 640000),inBitmap 池,统一 ARGB_8888 | `classes2/.../aiunit/vision/b49.java`、`p6b.java:363` |
| C. GalleryTileRegionDecoder | 放大瓦片 | JNI `nativeDecodeRegion(rect, sample)`,1024px tile | `classes10/.../galleryimagecodec/GalleryTileRegionDecoder.java:227`、`TileDrawable.java:416` |

**关键**:全库 `grep "compress|JPEG"` 只命中 MIME 枚举,**无任何 `Bitmap.compress()`**。Bitmap 解出即用,不 encode JPEG、不二次 decode。oplus 没有自定义静态图 Glide 解码器(`standard_lib/codec/glide/` 只有 GIF 定制),静态图全用 Glide 原版 Downsampler。

### 2.2 下采样数值

- **打开瞬间**(路径 B):`by70.c() = max(960, 屏宽物理×0.8)`。一加 13 屏宽 1440 → **~1152px**。
- Glide(路径 A):CENTER_OUTSIDE 按 Target 尺寸算 inSampleSize。
- 瓦片(路径 C):1024px tile,sampleSize 按 2 的幂从显示缩放比算。
- 像素上限(路径 B):640000。

### 2.3 打开动画 decode 时机

打开动画容器 `PhotoAnimatedReplacementView` 不解码(只是 View 替换壳 + spring/alpha)。真正显示图的是 `SkImageView`(画 TileDrawable)。打开瞬间通过资源服务后台协程解码到 ~1152px;首帧可能先画已缓存的列表缩略图承接,1152 就位后渐进到 2048(type 9)+ 原图瓦片。状态机 `FirstFrameRenderingStatus`(THUMBNAIL_READY→CONTENT_READY→ALL_READY)驱动首帧上报。

## 3. sortr 根因:JPEG 中转链

sortr 原链路(native decode → compress JPEG → dart 再 decode)比系统相册多两步 codec + 跨界字节拷贝:

| 步骤 | sortr(原)| 系统相册 |
|---|---|---|
| 1 | BitmapFactory 解 JPEG | BitmapFactory 解 JPEG(相同)|
| 2 | **compress JPEG 95 再编码**(~30-50ms)| 无 |
| 3 | **byte[] 跨 FFI 传 dart** | 无 |
| 4 | **dart/skia 再 decode JPEG**(~80-120ms,最慢)| 无 |
| 5 | 上 GPU 纹理 | Bitmap 直接上 ImageView |

光步骤 2+4 就 ~110-170ms,是「模糊全屏帧很久」的真凶。target 尺寸(2880/1920)只是次要因素。

## 4. 优化方案与实施

### P0 砍 JPEG 中转,改 raw 像素 buffer — ✅ 已实施
- Kotlin `readSampledImage`:不 compress,改 `bitmap.copyPixelsToBuffer` 出 ARGB_8888 raw + 宽高(`MediaStoreRepository.kt`)。
- channel 返回 `{pixels, width, height}`(`mediastore_channel.dart`)。
- dart `ImageDescriptor.raw(rgba8888)` + `instantiateCodec`,跳过二次 JPEG decode(`image_loader.dart`)。
- 字节序:Android ARGB_8888 copyPixelsToBuffer = RGBA,匹配 Flutter `rgba8888`。

### P1 target 改运行时屏宽×0.8 — ✅ 已实施
- `computeViewerTargetWidth(screenWidthPx) = max(960, 屏宽×0.8)`,对齐 `by70.c()`(`image_loader.dart`)。
- precache / `_BigImage` 原图层 / evict 三处都用本函数算同值(保 ImageCache key 一致)。
- 解码量 vs 1920 降约 64%。

### P2 Texture widget + native 直渲染 — ⏸ 未实施(终极方案)
- Kotlin 解码 Bitmap → SurfaceTexture → dart `Texture` widget。Bitmap 不离开 native,对等 Glide→ImageView。
- 改动大:新 plugin + 重写 `_BigImage`(换 Texture 范式)+ InteractiveViewer/PageView/飞行层适配 + 纹理生命周期管理。
- 性价比:P0 已拿根因 ~80%,P2 增量主要是省 raw 拷贝(~4MB),但改动与风险远大于 P0。仅当 P0 后仍感知卡顿且定位到是 raw 拷贝/GPU 上传瓶颈时再做。

### P3 放大 RegionDecoder 瓦片 — ⏸ 未实施
- 对标 `GalleryTileRegionDecoder`(`nativeDecodeRegion` + 1024px TileDrawable)。替掉 sortr `_hdTriggered` 的 readBytes 全图(后者放大时又走一遍跨界全图链)。
- 简化版(视口单块)平移体验差;完整瓦片系统(瓦片池 + 视口调度 + LRU)大工程。放大是低频操作,P0/P1 后暂缓,作单独专题。

### P4 inBitmap Bitmap 池复用 — ⏸ 未实施
- 对标 `a.java:179`(Options 池)、`b49.java:465`(inBitmap)。sortr Kotlin 侧每次 new,可加池减 GC。收益小、改动小。

## 5. 反编译产物与阅读方式

- `_reverse/gallery3d/`:`jadx_src/`(java,classes2..12 多 dex 分片)、`apktool_full/`(smali_classes1..16)、`ANALYSIS.md`(架构分析)。
- 跨 dex 搜:`grep -r "关键词" _reverse/gallery3d/jadx_src/`。
- 类名多被混淆成短名(a.java/b49.java 等),靠包路径 + 内部常量识别。
- 注:`a.java.b()`(Glide inSampleSize 精确算法)、`GalleryTileRegionDecoder.j()` jadx 标注 "Method dump skipped",相关结论按 Glide v4 标准语义推断。
