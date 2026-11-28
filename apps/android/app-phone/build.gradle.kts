plugins {
    id("dvplayer.android.application")
    id("dvplayer.android.compose")
}

android {
    namespace = "com.dvplayer.app"

    defaultConfig {
        applicationId = "com.dvplayer.app"

        // 手机端自己的版本线，和桌面端、TV 端都无关（见 gradle.properties）。
        versionName = providers.gradleProperty("dvplayer.phone.versionName").getOrElse("0.1.0")
        versionCode = providers.gradleProperty("dvplayer.phone.versionCode").orNull?.toIntOrNull() ?: 100
    }
}

dependencies {
    implementation(project(":ui-phone"))
    // 播放页 Activity 要自己套一层 DvTheme（ui-phone 的 design 是 implementation，不传递）。
    implementation(project(":design"))
    implementation(project(":core"))
    implementation(project(":player-mpv"))
    implementation(project(":player-media3"))
    implementation(libs.androidx.media3.ui)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.androidx.activity.compose)
    debugImplementation(libs.compose.ui.tooling)
}
