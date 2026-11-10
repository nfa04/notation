allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// some plugins leave their Java at 11 while their Kotlin follows the JDK: make
// the plugins agree with the app (Java and Kotlin 17)
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { android ->
            val base = android as com.android.build.gradle.BaseExtension
            base.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
            // a plugin that was last built against an older Android API than its own dependencies need (the check of AGP 9 refuses that)
            val compiledAgainst = base.compileSdkVersion?.removePrefix("android-")?.toIntOrNull() ?: 0
            if (compiledAgainst in 1..35) base.compileSdkVersion(36)
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
