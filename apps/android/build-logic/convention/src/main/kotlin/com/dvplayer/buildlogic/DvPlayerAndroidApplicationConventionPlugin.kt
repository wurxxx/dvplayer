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
                        // 只发 arm64-v8a。x86_64 只在本机 16KB 页模拟器调试时才
                        // 需要，显式 -Pdvplayer.debugAbi=x86_64 才带上（产物会白占
                        // 两份 .so 的体积，libmpv.so 一份就 28MB）。
                        abiFilters.add("arm64-v8a")
                        if (target.providers.gradleProperty("dvplayer.debugAbi").orNull == "x86_64") {
                            abiFilters.add("x86_64")
                        }
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
