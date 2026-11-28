pluginManagement {
    // 国内直连 Maven Central 常只有几百 KB/s。env.sh 会默认设置
    // DVPLAYER_MAVEN_MIRROR=https://maven.aliyun.com/repository；
    // 留空则完全走官方仓库。镜像里没有的 artifact 会继续往后找。
    val mirror = System.getenv("DVPLAYER_MAVEN_MIRROR")?.trim()?.trimEnd('/')

    repositories {
        if (!mirror.isNullOrEmpty()) {
            maven("$mirror/gradle-plugin")
            maven("$mirror/google")
            maven("$mirror/central")
        }
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    val mirror = System.getenv("DVPLAYER_MAVEN_MIRROR")?.trim()?.trimEnd('/')

    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        if (!mirror.isNullOrEmpty()) {
            maven("$mirror/google")
            maven("$mirror/central")
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "dvplayer-android"

include(":app-phone")
include(":app-tv")
include(":ui-phone")
include(":ui-tv")
include(":design")
include(":core")
include(":player")
include(":player-mpv")
include(":player-media3")

// 约定插件（compileSdk / minSdk / JDK 17 / Compose）
includeBuild("build-logic")
