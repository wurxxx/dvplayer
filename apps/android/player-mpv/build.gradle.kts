plugins {
    id("dvplayer.android.library")
}

android {
    namespace = "com.dvplayer.player.mpv"

    ndkVersion = "28.2.13676358"

    defaultConfig {
        ndk {
            abiFilters.add("arm64-v8a")
            // 16KB 页模拟器（x86_64）调试用，和 application 的开关同一个属性。
            if (project.providers.gradleProperty("dvplayer.debugAbi").orNull == "x86_64") {
                abiFilters.add("x86_64")
            }
        }

        externalNativeBuild {
            cmake {
                // libmpv.so 不在仓库里，先跑 scripts/android/build-mpv.sh 生成。
                val mpvRoot = rootProject.projectDir.parentFile.parentFile
                    .resolve("build/android-mpv").absolutePath
                arguments += "-DMPV_ROOT=$mpvRoot"
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    api(project(":player"))
}
