import com.android.build.api.dsl.ApplicationExtension
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key of a release build: android/key.properties (never committed, see android/.gitignore) with storeFile, storePassword,
// keyAlias and keyPassword. Without it a release build is signed with the debug key, which only does for `flutter run --release`.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

configure<ApplicationExtension> {
    namespace = "io.github.nfa04.notation"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (reminders) needs the newer java.time classes on older phones
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.nfa04.notation"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        // QNN's Hexagon libraries are loaded by the phone's DSP from a file on disk: the libraries must be unpacked at install
        jniLibs { useLegacyPackaging = true }
    }

    signingConfigs {
        if (!keystoreProperties.isEmpty) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        getByName("release") {
            val releaseKey = signingConfigs.findByName("release")
            if (releaseKey == null) {
                // (F-Droid and the builds of the CI sign the file themselves, or not at all: this is only a warning. A build that is
                // meant for a store passes `-PrequireReleaseKey=true` and stops here instead)
                if (project.findProperty("requireReleaseKey") == "true") {
                    throw GradleException("android/key.properties is missing: this release build would be signed with the DEBUG key.")
                }
                logger.warn("android/key.properties is missing: this release build is signed with the DEBUG key and cannot be published.")
            }
            signingConfig = releaseKey ?: signingConfigs.getByName("debug")
            // the model runtimes need their classes untouched (see proguard-rules.pro)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
