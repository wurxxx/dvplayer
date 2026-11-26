package com.dvplayer.core.vfs.nfs

import java.nio.charset.StandardCharsets

/**
 * XDR（RFC 4506）编码器——ONC RPC / NFSv3 的序列化格式。
 *
 * 一切都是 4 字节大端：整数直接写，`opaque<>` / `string<>` 前面带长度，
 * 数据部分补零到 4 的倍数。手写而不是引入 jrpcgen 之类的生成器，
 * 是因为整个 NFS 客户端只用到十几个结构，生成器与它的运行时反而更大。
 */
internal class XdrWriter(initialCapacity: Int = 512) {

    private var buf = ByteArray(initialCapacity.coerceAtLeast(32))
    private var size = 0

    val length: Int get() = size

    private fun ensure(n: Int) {
        if (size + n <= buf.size) return
        var cap = buf.size
        while (cap < size + n) cap = cap shl 1
        buf = buf.copyOf(cap)
    }

    fun u32(value: Int): XdrWriter {
        ensure(4)
        buf[size++] = (value ushr 24).toByte()
        buf[size++] = (value ushr 16).toByte()
        buf[size++] = (value ushr 8).toByte()
        buf[size++] = value.toByte()
        return this
    }

    fun u64(value: Long): XdrWriter = u32((value ushr 32).toInt()).u32(value.toInt())

    fun bool(value: Boolean): XdrWriter = u32(if (value) 1 else 0)

    /** 定长字节：只补零，不加长度前缀（cookieverf 之类）。 */
    fun fixed(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size): XdrWriter {
        ensure(count + padding(count))
        System.arraycopy(bytes, offset, buf, size, count)
        size += count
        repeat(padding(count)) { buf[size++] = 0 }
        return this
    }

    /** 变长 `opaque<>`：长度前缀 + 数据 + 补零。 */
    fun opaque(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size): XdrWriter {
        u32(count)
        return fixed(bytes, offset, count)
    }

    fun string(value: String): XdrWriter = opaque(value.toByteArray(StandardCharsets.UTF_8))

    fun toByteArray(): ByteArray = buf.copyOf(size)

    private fun padding(n: Int): Int = (4 - (n and 3)) and 3
}

/**
 * XDR 解码器。越界一律抛 [XdrException]：服务器的畸形回复不能变成
 * `IndexOutOfBoundsException` 混进上层业务异常里。
 */
internal class XdrReader(
    private val buf: ByteArray,
    private var pos: Int = 0,
    private val end: Int = buf.size,
) {

    val remaining: Int get() = end - pos

    fun u32(): Int {
        need(4)
        val v = ((buf[pos].toInt() and 0xff) shl 24) or
            ((buf[pos + 1].toInt() and 0xff) shl 16) or
            ((buf[pos + 2].toInt() and 0xff) shl 8) or
            (buf[pos + 3].toInt() and 0xff)
        pos += 4
        return v
    }

    fun u64(): Long = ((u32().toLong() and 0xffffffffL) shl 32) or (u32().toLong() and 0xffffffffL)

    fun bool(): Boolean = u32() != 0

    fun fixed(count: Int): ByteArray {
        need(count)
        val out = buf.copyOfRange(pos, pos + count)
        pos += count
        // XDR 一定补零；个别实现的最后一段可能省略，能跳就跳。
        val pad = padding(count)
        if (end - pos >= pad) pos += pad
        return out
    }

    fun opaque(): ByteArray {
        val len = u32()
        if (len < 0 || len > remaining) {
            throw XdrException("opaque 长度越界：$len，剩余 $remaining")
        }
        return fixed(len)
    }

    fun string(): String = String(opaque(), StandardCharsets.UTF_8)

    fun skip(n: Int) {
        need(n)
        pos += n
    }

    private fun padding(n: Int): Int = (4 - (n and 3)) and 3

    private fun need(n: Int) {
        if (n < 0 || end - pos < n) {
            throw XdrException("XDR 数据不足：需要 $n 字节，还剩 ${end - pos}")
        }
    }
}

class XdrException(message: String) : java.io.IOException(message)
