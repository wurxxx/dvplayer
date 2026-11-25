plugins {
    id("dvplayer.android.library")
    id("dvplayer.android.compose")
}

android {
    namespace = "com.dvplayer.ui.phone"
}

dependencies {
    implementation(project(":design"))
    implementation(project(":core"))

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    debugImplementation(libs.compose.ui.tooling)
}
