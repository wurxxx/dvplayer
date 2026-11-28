package com.dvplayer.buildlogic

import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import java.io.File

class DvPlayerAndroidApplicationConventionPlugin : Plugin<Project> {

    override fun apply(target: Project) {
        with(target) {
            pluginManager.apply("com.android.application")
            pluginManager.apply("org.jetbrains.kotlin.android")

            // 发版签名：密钥放在 CI 的 Secrets 里，落地成文件后由环境变量指过来。
            // 没有就退回 debug 签名——本机 assembleRelease 照常能装，CI 的 release
            // job 会自己检查密钥在不在，不靠这里的兜底。
            val keystoreEnv = System.getenv("DVPLAYER_ANDROID_KEYSTORE")?.takeIf { it.isNotBlank() }
            val keystore = keystoreEnv?.let(::File)?.takeIf { it.isFile }
            if (keystoreEnv != null && keystore == null) {
                logger.warn("DVPLAYER_ANDROID_KEYSTORE 指的文件不存在：$keystoreEnv，这次用 debug 签名。")
            }

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

                signingConfigs {
                    if (keystore != null) {
                        create("release") {
                            storeFile = keystore
                            storePassword = System.getenv("DVPLAYER_ANDROID_STORE_PASSWORD")
                            keyAlias = System.getenv("DVPLAYER_ANDROID_KEY_ALIAS")
                            keyPassword = System.getenv("DVPLAYER_ANDROID_KEY_PASSWORD")
                        }
                    }
                }

                buildTypes {
                    getByName("release") {
                        isMinifyEnabled = false
                        // 发版密钥缺失时用 debug 签名，和原来各模块里的写法等价。
                        signingConfig = signingConfigs.findByName("release")
                            ?: signingConfigs.getByName("debug")
                    }
                }
            }

            configureKotlinJvmTarget()
        }
    }
}
