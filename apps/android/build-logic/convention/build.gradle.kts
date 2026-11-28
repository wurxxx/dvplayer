plugins {
    `kotlin-dsl`
}

group = "com.dvplayer.buildlogic"

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
}

dependencies {
    // AGP / KGP 由主工程的 plugins {} 提供，这里只需要编译期类型。
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
}

gradlePlugin {
    plugins {
        register("androidApplication") {
            id = "dvplayer.android.application"
            implementationClass = "com.dvplayer.buildlogic.DvPlayerAndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = "dvplayer.android.library"
            implementationClass = "com.dvplayer.buildlogic.DvPlayerAndroidLibraryConventionPlugin"
        }
        register("androidCompose") {
            id = "dvplayer.android.compose"
            implementationClass = "com.dvplayer.buildlogic.DvPlayerAndroidComposeConventionPlugin"
        }
    }
}
