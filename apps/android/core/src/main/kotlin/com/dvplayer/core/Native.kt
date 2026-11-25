package com.dvplayer.core

/**
 * 共享核心的 native 入口。
 *
 * A0 只有 [version] 一个自检函数，用来验证 jniLibs 打包与 16KB 页；
 * A3 起这里会补齐 41 个 `dv_*` 的声明与 camelCase 模型。
 */
object Native {
    init {
        System.loadLibrary("dvplayer_media_jni")
    }

    external fun version(): String
}
