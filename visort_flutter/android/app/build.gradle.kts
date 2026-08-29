import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // AGP 9 内置 Kotlin 编译（built-in Kotlin），不再 apply kotlin-android——
    // 旧 apply 会让 android{} 解析到 BaseAppModuleExtension（AGP 9 移除路径）。
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 生产签名配置（android/key.properties，已 gitignore；keystore 在仓库外）。
// 缺失时回落 debug 签名，保住本地 `flutter run --release` 工作流——
// 但对外发版必须用固定 keystore：CI runner 的 debug key 每次不同，
// 签名不固定则用户无法覆盖升级（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.synxvi.visort"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.synxvi.visort"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 30（Android 11+，2026-08 决策）：放弃 Android 8-10 存量——
        // Q(29)/pre-Q 的存储授权分支（RecoverableSecurityException 探针、
        // 直删重放、TRASH/FAVORITE_UNSUPPORTED 降级）从未被真机覆盖且已
        // 确认含多处缺陷，维护成本大于用户收益（GitHub 分发、无 ≤10 用户）。
        // 30 同时保证 createTrashRequest/createDeleteRequest/createWriteRequest
        // 全系可用。历史下限 26 的理由（bundle-query 需 26+）已被 30 覆盖。
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 用生产签名；无则回落 debug（仅限本地调试用）。
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")

            // R8 代码压缩 + 资源压缩。
            // 剔除未引用的 Java/Kotlin 代码与资源，减小 DEX 与 APK 体积，
            // 加快类加载与冷启动。keep 规则见 proguard-rules.pro。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    // 跳过 release 的 vital lint 检查：该任务会联网卡住，且对打包/功能无影响。
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    // 按 ABI 拆分 APK：每个架构只含对应的 libflutter.so / libapp.so，
    // 避免单包内冗余多架构 native 库（fat APK 通常翻倍）。
    // 保留 universalApk 兜底手动安装场景；Play/分发用分包。
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a")
            isUniversalApk = true
        }
    }

    // 打包层剔除 sqlite3_flutter_libs 捆绑的原生库（安卓走系统 SQLite，
    // 详见文件底部说明）。该库由插件子项目自行解析依赖，
    // configurations.exclude 管不到（实测不生效），故在 merge 阶段剔除。
    packaging {
        jniLibs {
            excludes += "lib/**/libsqlite3.so"
        }
    }
}

// kotlinOptions 已废弃（Kotlin 2.3 移除路径），迁移 compilerOptions DSL。
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// per-ABI versionCode 偏移：splits 三个 APK 共用 flutter.versionCode 会全部
// 相同（此前实测三个包 code 均为 1）。这里设 N*10 基数，AGP splits 再自动
// 叠加 1000 位 ABI 偏移——实测（versionCode=2）：universal=20、
// arm64-v8a=1020、armeabi-v7a=2020，三包互异且各自随版本单调递增，
// 满足直装渠道的覆盖升级判定（同包 code 单调即可，跨包不比较）。
// AGP 9 中 applicationVariants.all 已移除，须走 androidComponents API。
androidComponents {
    onVariants { variant ->
        variant.outputs.forEach { output ->
            val abi = output.filters.firstOrNull {
                it.filterType == com.android.build.api.variant.FilterConfiguration.FilterType.ABI
            }?.identifier
            val offset = when (abi) {
                "armeabi-v7a" -> 2
                "arm64-v8a" -> 1
                else -> 0 // universal
            }
            output.versionCode.set((flutter.versionCode ?: 1) * 10 + offset)
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // EXIF/元数据读取（P0 详情抽屉）。
    // exifinterface：AndroidX ExifInterface，读 JPEG/TIFF EXIF（朝向/GPS/时间）。
    // metadata-extractor：兜底多格式元数据（IPTC/XMP/PNG/RAW），覆盖 ExifInterface 不支持的容器。
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("com.drewnoakes:metadata-extractor:2.19.0")
    // WorkManager：全库预缓存后台任务（充电+存储不低约束的可靠调度，
    // 跨进程/设备重启续跑）。KTX 版提供 CoroutineWorker/suspend 支持；
    // 仅用经典 Worker 也走此依赖（work-runtime 被 ktx 传递包含）。
    implementation("androidx.work:work-runtime-ktx:2.10.0")
}

// 安卓端 SQLite 走 sqflite method-channel → 系统 SQLite(android.database)，
// sqlite3_flutter_libs 捆绑的 libsqlite3.so 只服务桌面 ffi 路径，在安卓是
// 死重（arm64 1.7MB / v7a 1.6MB 未压缩）。插件注册代码极小照常保留；
// Windows 端不走安卓打包，不受影响。剔除动作见上方 packaging.jniLibs。
