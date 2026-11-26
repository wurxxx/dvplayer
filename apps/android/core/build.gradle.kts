plugins {
    id("dvplayer.android.library")
}

android {
    namespace = "com.dvplayer.core"
}

dependencies {
    // WebDAV 的 PROPFIND 是自定义方法，平台 HttpURLConnection 不允许。
    implementation(libs.okhttp)
    // SMB2/3 客户端（A9）。
    implementation(libs.smbj)
}
