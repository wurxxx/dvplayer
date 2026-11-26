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
                        // 只发 arm64-v8a。x86_64 只在本机用模拟器调试时才需要，
                        // 产物会白占两份 .so 的体积（libmpv.so 一份就 25MB+）。
                        abiFilters.add("arm64-v8a")
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
