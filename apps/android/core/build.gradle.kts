plugins {
    id("dvplayer.android.library")
    // 核心 JSON 契约（`{"ok":…,"data":…}`）直接映射成 @Serializable 模型。
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.dvplayer.core"
}

dependencies {
    // WebDAV 的 PROPFIND 是自定义方法，平台 HttpURLConnection 不允许。
    implementation(libs.okhttp)
    // SMB2/3 客户端（A9）。
    implementation(libs.smbj)
    // 共享核心的 JSON 外壳与模型。
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
}
