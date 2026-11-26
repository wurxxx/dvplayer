plugins {
    id("dvplayer.android.library")
}

android {
    namespace = "com.dvplayer.player.mpv"

    ndkVersion = "28.2.13676358"

    defaultConfig {
        ndk {
            abiFilters.add("arm64-v8a")
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
