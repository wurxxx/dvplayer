plugins {
    id("dvplayer.android.library")
    id("dvplayer.android.compose")
}

android {
    namespace = "com.dvplayer.design"
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
}
