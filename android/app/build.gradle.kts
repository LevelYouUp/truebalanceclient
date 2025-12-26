import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.levelyouup.truebalanceathome"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // Enable core library desugaring for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.levelyouup.truebalanceathome"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            // Use release signing config
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Customize APK output file names - must be OUTSIDE android block
android.applicationVariants.all {
    outputs.all {
        val output = this as com.android.build.gradle.internal.api.BaseVariantOutputImpl
        val versionName = android.defaultConfig.versionName
        val versionCode = android.defaultConfig.versionCode
        val buildType = this.name
        
        // Format: TrueBalance-v1.0.0-1-debug.apk or TrueBalance-v1.0.0-1-release.apk
        output.outputFileName = "TrueBalance-v${versionName}-${versionCode}-${buildType}.apk"
    }
}

flutter {
    source = "../.."
}

configurations.all {
    resolutionStrategy {
        force("androidx.media3:media3-exoplayer:1.3.1")
        force("androidx.media3:media3-common:1.3.1")
        force("androidx.media3:media3-extractor:1.3.1")
        force("androidx.media3:media3-exoplayer-hls:1.3.1")
        force("androidx.media3:media3-exoplayer-dash:1.3.1")
        force("androidx.media3:media3-exoplayer-rtsp:1.3.1")
        force("androidx.media3:media3-exoplayer-smoothstreaming:1.3.1")
        force("androidx.media3:media3-datasource:1.3.1")
        force("androidx.media3:media3-decoder:1.3.1")
    }
}

dependencies {
    // Core library desugaring for flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
