package com.dvplayer.buildlogic

import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure

class DvPlayerAndroidLibraryConventionPlugin : Plugin<Project> {

    override fun apply(target: Project) {
        with(target) {
            pluginManager.apply("com.android.library")
            pluginManager.apply("org.jetbrains.kotlin.android")

            extensions.configure<LibraryExtension> {
                compileSdk = AndroidBaseline.COMPILE_SDK

                defaultConfig {
                    minSdk = AndroidBaseline.MIN_SDK
                }

                compileOptions {
                    sourceCompatibility = AndroidBaseline.JAVA_VERSION
                    targetCompatibility = AndroidBaseline.JAVA_VERSION
                }

                packaging {
                    jniLibs {
                        useLegacyPackaging = false
                    }
                }

                // local unit test 里 android.util.Log 之类平台调用返回默认值，
                // 纯解析 / 决策逻辑才能直接在 JVM 上跑（:player 的测试）。
                testOptions {
                    unitTests.isReturnDefaultValues = true
                }
            }

            configureKotlinJvmTarget()
        }
    }
}
