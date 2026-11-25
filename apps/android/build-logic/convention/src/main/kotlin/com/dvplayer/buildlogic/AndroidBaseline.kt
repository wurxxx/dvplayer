package com.dvplayer.buildlogic

import org.gradle.api.JavaVersion
import org.gradle.api.Project
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

/**
 * 两个 application / library 模块共用的基线，数值见 docs/M2-ANDROID.md §7 与
 * apps/android/README.md：
 *
 * - minSdk 26，compileSdk / targetSdk 36
 * - JDK 17（桌面端是 11，别混）
 * - 16KB 页：native 库不压缩打包
 */
internal object AndroidBaseline {
    const val COMPILE_SDK = 36
    const val TARGET_SDK = 36
    const val MIN_SDK = 26

    val JAVA_VERSION: JavaVersion = JavaVersion.VERSION_17
}

/** Kotlin 的 jvmTarget 和 Java 的 compileOptions 必须一致，否则 AGP 会报错。 */
internal fun Project.configureKotlinJvmTarget() {
    tasks.withType(KotlinJvmCompile::class.java).configureEach {
        compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
    }
}
