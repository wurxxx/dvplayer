package com.dvplayer.buildlogic

import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project

/**
 * Compose 只做两件事：应用 Kotlin 的 Compose 编译器插件、打开 buildFeatures.compose。
 * 具体依赖（BOM / material3 / tv-material）由各模块自己声明，避免约定插件去读
 * 版本目录。
 */
class DvPlayerAndroidComposeConventionPlugin : Plugin<Project> {

    override fun apply(target: Project) {
        with(target) {
            pluginManager.apply("org.jetbrains.kotlin.plugin.compose")

            extensions.findByType(ApplicationExtension::class.java)?.let { android ->
                android.buildFeatures.compose = true
            }
            extensions.findByType(LibraryExtension::class.java)?.let { android ->
                android.buildFeatures.compose = true
            }
        }
    }
}
