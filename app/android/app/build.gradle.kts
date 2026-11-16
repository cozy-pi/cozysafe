plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CS_BETA=1 builds "Cozy Safe Beta": its own application id, so it installs next to Cozy Safe
// with its own data (work in progress never touches a real vault). Set by CI only
// (release.yml, beta=true).
val beta = System.getenv("CS_BETA") == "1"

android {
    namespace = "com.cozypi.cozysafe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.cozypi.cozysafe"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (beta) applicationIdSuffix = ".beta"
        manifestPlaceholders["appLabel"] = if (beta) "Cozy Safe Beta" else "Cozy Safe"
    }

    // Release key comes from CI secrets (ANDROID_KEYSTORE_*); without them (local
    // `flutter run --release`) the build falls back to the debug key.
    val releaseKeystore = System.getenv("CS_ANDROID_KEYSTORE")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storeType = "pkcs12"
                storePassword = System.getenv("CS_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "cozysafe"
                keyPassword = System.getenv("CS_ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Google Block Store for the 24 words (BlockStore.kt); already resolved for the
    // Credential Manager, so verification-metadata.xml has it.
    implementation("com.google.android.gms:play-services-auth-blockstore:16.4.0")
}
