package com.dvplayer.core.vfs

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * 把 [VfsFile] 通过 `127.0.0.1` 的 HTTP 暴露给播放内核（A9）。
 *
 * mpv 与 Media3 都不认识 `smb://`，而 SMB / NFS 的随机读我们已经有了统一的
 * [VfsFile]。这个小服务只做三件事：GET、HEAD、`Range`——正是两个内核播放与
 * seek 需要的最小集合。地址只绑定本机回环，端口随机。
 *
 * 必须支持 keep-alive：4K 片源每秒要几十次 64KB 读，一个请求一个 TCP 连接
 * 会让播放卡死；这里在同一个 socket 上循环处理请求。
 *
 * 一个桥接实例服务一个文件；正式实现可以按 token 注册多个，当前验证页够用。
 */
class VfsHttpBridge(
    private val file: VfsFile,
    private val name: String = "media",
) {

    private val tag = "DvBridge"
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val running = AtomicBoolean(true)
    private val requests = AtomicInteger(0)

    val url: String
        get() = "http://127.0.0.1:${server.localPort}/$name"

    fun start() {
        thread(name = "vfs-bridge", isDaemon = true) {
            Log.i(tag, "桥接启动：$url（${file.size} 字节）")
            while (running.get()) {
                val socket = try {
                    server.accept()
                } catch (t: Throwable) {
                    if (running.get()) Log.w(tag, "accept 失败", t)
                    break
                }
                thread(name = "vfs-bridge-conn", isDaemon = true) {
                    // 任何异常都只影响这一条连接：未捕获异常会直接杀掉进程。
                    runCatching { socket.use { serve(it) } }
                        .onFailure { t -> if (running.get()) Log.w(tag, "连接结束：${t.message}") }
                }
            }
        }
    }

    fun close() {
        running.set(false)
        runCatching { server.close() }
        runCatching { file.close() }
        Log.i(tag, "桥接关闭")
    }

    private fun serve(socket: Socket) {
        socket.soTimeout = 30_000
        socket.tcpNoDelay = true
        val input = BufferedInputStream(socket.getInputStream())
        val output = BufferedOutputStream(socket.getOutputStream())
        while (running.get()) {
            val requestLine = readLine(input) ?: return
            if (requestLine.isBlank()) continue
            val parts = requestLine.split(' ')
            if (parts.size < 2) return
            val method = parts[0]
            var http10 = parts.size > 2 && parts[2].contains("HTTP/1.0")
            var range: String? = null
            var keepAlive = true
            // 读完请求头：只需要 Range / Connection。
            while (true) {
                val line = readLine(input) ?: return
                if (line.isEmpty()) break
                val idx = line.indexOf(':')
                if (idx <= 0) continue
                val header = line.substring(0, idx).trim()
                val value = line.substring(idx + 1).trim()
                when {
                    header.equals("Range", ignoreCase = true) -> range = value
                    header.equals("Connection", ignoreCase = true) ->
                        keepAlive = !value.equals("close", ignoreCase = true)
                }
            }
            if (http10 && !requestLine.contains("keep-alive", ignoreCase = true)) {
                keepAlive = false
            }
            if (method != "GET" && method != "HEAD") {
                output.write(
                    "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .toByteArray(),
                )
                output.flush()
                return
            }

            val size = file.size
            if (size <= 0) {
                output.write(
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .toByteArray(),
                )
                output.flush()
                return
            }
            var start = 0L
            var end = size - 1
            var status = "200 OK"
            when (val parsed = parseByteRange(range, size)) {
                is ByteRange.Partial -> {
                    start = parsed.start
                    end = parsed.end
                    status = "206 Partial Content"
                }
                ByteRange.Unsatisfiable -> {
                    output.write(
                        ("HTTP/1.1 416 Range Not Satisfiable\r\n" +
                            "Content-Range: bytes */$size\r\n" +
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray(),
                    )
                    output.flush()
                    return
                }
                ByteRange.Full -> Unit
            }
            val length = (end - start + 1).coerceAtLeast(0)
            val n = requests.incrementAndGet()
            if (n <= 5 || n % 200 == 0) {
                Log.i(tag, "#$n $method ${range ?: "(全量)"} -> $status $start-$end/$size")
            }

            val head = buildString {
                append("HTTP/1.1 $status\r\n")
                append("Content-Type: application/octet-stream\r\n")
                append("Accept-Ranges: bytes\r\n")
                append("Content-Length: $length\r\n")
                if (status.startsWith("206")) {
                    append("Content-Range: bytes $start-$end/$size\r\n")
                }
                append(if (keepAlive) "Connection: keep-alive\r\n\r\n" else "Connection: close\r\n\r\n")
            }
            output.write(head.toByteArray())
            if (method == "GET") {
                val buffer = ByteArray(READ_CHUNK)
                var offset = start
                var remaining = length
                while (remaining > 0) {
                    val want = minOf(buffer.size.toLong(), remaining).toInt()
                    val read = try {
                        file.read(offset, buffer, want)
                    } catch (t: Throwable) {
                        Log.w(tag, "读 $offset 失败：${t.message}")
                        return
                    }
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    offset += read
                    remaining -= read
                }
            }
            output.flush()
            if (!keepAlive) return
        }
    }

    private fun readLine(input: BufferedInputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) {
                if (sb.isEmpty()) return null
                throw EOFException("请求行不完整")
            }
            if (b == '\n'.code) break
            if (b != '\r'.code) sb.append(b.toChar())
        }
        return sb.toString()
    }

    private companion object {
        const val READ_CHUNK = 256 * 1024
    }
}
