package com.dvplayer.player.mpv

import android.view.Surface

/**
 * mpv 内核的最小封装（A4 第一步）。
 *
 * 只做「把 Surface 交给 mpv、把文件丢给 mpv」；属性桥、轨道、字幕等到 A4 的
 * 后半段再补。所有调用都必须在主线程以外的线程吗？不——`command` / `setProperty`
 * 内部走 libmpv 的命令队列，可以从主线程调用；`attach` / `detach` 只是投递
 * Surface，也是非阻塞的。
 */
class MpvPlayer : AutoCloseable {

    private var handle: Long = MpvNative.create()

    val isValid: Boolean get() = handle != 0L

    fun attach(surface: Surface, width: Int, height: Int) {
        if (handle != 0L) MpvNative.attach(handle, surface, width, height)
    }

    fun detach() {
        if (handle != 0L) MpvNative.detach(handle)
    }

    fun command(vararg args: String): String? =
        if (handle == 0L) "player 已释放" else MpvNative.command(handle, Array(args.size) { args[it] })

    fun setProperty(name: String, value: String): String? =
        if (handle == 0L) "player 已释放" else MpvNative.setProperty(handle, name, value)

    fun getProperty(name: String): String? =
        if (handle == 0L) null else MpvNative.getProperty(handle, name)

    /** GL 就绪前的调用会被 native 侧暂存，等 render context 建好再真正加载。 */
    fun play(url: String) {
        if (handle != 0L) MpvNative.play(handle, url)
    }

    override fun close() {
        val h = handle
        handle = 0L
        if (h != 0L) MpvNative.destroy(h)
    }
}

internal object MpvNative {
    init {
        System.loadLibrary("dvplayer_mpv")
    }

    external fun create(): Long

    external fun attach(handle: Long, surface: Surface, width: Int, height: Int)

    external fun play(handle: Long, url: String)

    external fun detach(handle: Long)

    external fun command(handle: Long, args: Array<String>): String?

    external fun setProperty(handle: Long, name: String, value: String): String?

    external fun getProperty(handle: Long, name: String): String?

    external fun destroy(handle: Long)
}
