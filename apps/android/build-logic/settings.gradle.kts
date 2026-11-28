pluginManagement {
    val mirror = System.getenv("DVPLAYER_MAVEN_MIRROR")?.trim()?.trimEnd('/')

    repositories {
        if (!mirror.isNullOrEmpty()) {
            maven("$mirror/gradle-plugin")
            maven("$mirror/google")
            maven("$mirror/central")
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    val mirror = System.getenv("DVPLAYER_MAVEN_MIRROR")?.trim()?.trimEnd('/')

    repositories {
        if (!mirror.isNullOrEmpty()) {
            maven("$mirror/google")
            maven("$mirror/central")
        }
        google()
        mavenCentral()
    }
    // 与主工程共用一份版本目录：约定插件里 compileOnly 的 AGP / KGP 版本
    // 不会和模块里用的版本漂移。
    versionCatalogs {
        create("libs") {
            from(files("../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "build-logic"
include(":convention")
