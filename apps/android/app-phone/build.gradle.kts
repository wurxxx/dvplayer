plugins {
    id("dvplayer.android.application")
    id("dvplayer.android.compose")
}

android {
    namespace = "com.dvplayer.app"

    defaultConfig {
        applicationId = "com.dvplayer.app"
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation(project(":ui-phone"))
    implementation(project(":core"))
    implementation(project(":player-mpv"))
    implementation(project(":player-media3"))
    implementation(libs.androidx.media3.ui)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.androidx.activity.compose)
    debugImplementation(libs.compose.ui.tooling)
}
