plugins {
    id("dvplayer.android.application")
    id("dvplayer.android.compose")
}

android {
    namespace = "com.dvplayer.app.tv"

    defaultConfig {
        applicationId = "com.dvplayer.app.tv"

        // TV 端自己的版本线：界面还没做完，不跟手机端一起涨（见 gradle.properties）。
        versionName = providers.gradleProperty("dvplayer.tv.versionName").getOrElse("0.1.0")
        versionCode = providers.gradleProperty("dvplayer.tv.versionCode").orNull?.toIntOrNull() ?: 100
    }
}

dependencies {
    implementation(project(":ui-tv"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.androidx.activity.compose)
    debugImplementation(libs.compose.ui.tooling)
}
