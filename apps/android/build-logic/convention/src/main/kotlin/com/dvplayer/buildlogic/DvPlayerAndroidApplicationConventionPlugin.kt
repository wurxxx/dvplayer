package com.dvplayer.buildlogic

import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure

class DvPlayerAndroidApplicationConventionPlugin : Plugin<Project> {

    override fun apply(target: Project) {
        with(target) {
            pluginManager.apply("com.android.application")
            pluginManager.apply("org.jetbrains.kotlin.android")

            extensions.configure<ApplicationExtension> {
                compileSdk = AndroidBaseline.COMPILE_SDK

                defaultConfig {
                    minSdk = AndroidBaseline.MIN_SDK
                    targetSdk = AndroidBaseline.TARGET_SDK
                    vectorDrawables.useSupportLibrary = true

                    ndk {
                        // 目前只编了这两个 ABI 的 native 库；其余 ABI 进包也只是
                        // 白占体积，而且 loadLibrary 会直接失败。
                        abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
                    }
                }

                compileOptions {
                    sourceCompatibility = AndroidBaseline.JAVA_VERSION
                    targetCompatibility = AndroidBaseline.JAVA_VERSION
                }

                packaging {
                    jniLibs {
                        // 不压缩、安装时不解包：16KB 页设备上才能直接 mmap 加载。
                        useLegacyPackaging = false
                    }
                    resources {
                        excludes += "/META-INF/{AL2.0,LGPL2.1}"
                    }
                }
            }

            configureKotlinJvmTarget()
        }
    }
}
