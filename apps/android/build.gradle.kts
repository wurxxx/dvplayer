// 版本全部走 gradle/libs.versions.toml；这里只声明插件，实际应用在
// build-logic 的约定插件与各模块里。
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
