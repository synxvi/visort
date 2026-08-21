plugins {
    id("com.android.application")
    // AGP 9 内置 Kotlin 编译（built-in Kotlin），不再 apply kotlin-android——
    // 旧 apply 会让 android{} 解析到 BaseAppModuleExtension（AGP 9 移除路径）。
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

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
}

// kotlinOptions 已废弃（Kotlin 2.3 移除路径），迁移 compilerOptions DSL。
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
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
}
