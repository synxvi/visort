# ─────────────────────────────────────────────────────────────
# VISORT Flutter —— R8 / ProGuard keep 规则
# ─────────────────────────────────────────────────────────────
# 配合 app/build.gradle.kts 的 isMinifyEnabled=true 使用。
# 本应用自定义插件通过 MainActivity.configureFlutterEngine() 直接
# add() 注册（非反射），R8 默认不会剔除；以下规则作双保险。

# ── Flutter 引擎与嵌入层（Flutter 工具链建议的标准 keep）──
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ── 本应用自定义原生插件（MediaStorePlugin / SafPlugin 及其 Model/Repository）──
# MethodChannel 回调的方法名（onMethodCall 内 when 分支）不应被混淆重命名，
# 否则 Dart 侧 invokeMethod 找不到对应 handler。
-keep class com.synxvi.visort.** { *; }

# ── Kotlin 元数据 / 注解 / 泛型签名（R8 默认有时会剥离）──
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod, Exceptions

# ── 日志剥离（2026-09 安全审查）：批量文件 id / 移动目标路径 / rename
# 新名等 Log.i/w 沉淀在 release logcat 环形缓冲，属行为画像数据。
# 剥离 v/d/i（保留 w/e 供排障——剥离 w 会丢真实异常轨迹）。
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# AndroidX 与常见误报警告
-dontwarn javax.annotation.**
-dontwarn org.jetbrains.annotations.**

# ── Flutter 引擎引用的 Play Core（延迟组件 / Play Feature Delivery）──
# 本项目不通过 Play Store 分发延迟组件，未引入 play-core 依赖，
# R8 严格模式会把引擎里对这些类的引用当作缺失类而报错。忽略即可。
# （规则由 AGP 自动生成于 build/.../missing_rules.txt）
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# ── metadata-extractor（P0 EXIF 提取）──
# 该库遍历 com.drew.metadata.* 各 Directory 子类提取元数据，
# R8 严格模式可能裁剪未被直接引用的 Directory 实现，保留整个包。
-keep class com.drew.** { *; }
-dontwarn com.drew.**

# ── WorkManager（R8 full mode 反射缺口）──
# WorkManagerInitializer 在启动 ContentProvider 阶段反射构造 Room 生成类
# WorkDatabase_Impl 的无参 <init>（getDeclaredConstructor）。AGP 9 / R8
# full mode 下 work-runtime 自带 consumer rules 对该生成类覆盖不全，
# 构造器被裁 → NoSuchMethodException → 启动即崩（真机实证 08-29）。
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class androidx.work.impl.WorkDatabase_Impl$* { *; }
