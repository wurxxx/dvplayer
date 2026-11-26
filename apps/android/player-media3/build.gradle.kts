plugins {
    id("dvplayer.android.library")
}

android {
    namespace = "com.dvplayer.player.media3"
}

dependencies {
    api(project(":player"))
    api(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.ui)
}
