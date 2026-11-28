package com.dvplayer.core.vfs.nfs

import com.dvplayer.core.vfs.NfsVfs
import com.dvplayer.core.vfs.VfsHttpBridge
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

/**
 * NFSv3 客户端对真实协议实现（[FakeNfsServer] 在回环上跑）的端到端测试。
 *
 * 覆盖：rpcbind 端口注入、MOUNT 逐级回退、AUTH_SYS、LOOKUP、READDIRPLUS
 * 分页、READ 的偏移 / 长度，以及经 [VfsHttpBridge] 的 HTTP Range 播放路径。
 */
class NfsVfsTest {

    private fun server(): FakeNfsServer = FakeNfsServer("/export").apply {
        put("/export/readme.txt", isDir = false, content = "hello nfs".toByteArray())
        put("/export/movies/a.mkv", isDir = false, content = ByteArray(300_000) { (it % 251).toByte() })
        put("/export/movies/b.mkv", isDir = false, content = "b".toByteArray())
        put("/export/movies/子目录/c.mkv", isDir = false, content = "c".toByteArray())
    }

    private fun vfs(server: FakeNfsServer, url: String, uid: Int = 0, gid: Int = 0): NfsVfs =
        NfsVfs(
            url,
            Nfs3Client(
                host = "127.0.0.1",
                uid = uid,
                gid = gid,
                portResolver = { _, _ -> server.port },
            ),
        )

    @Test
    fun `列目录带大小与目录标记`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/export").use { vfs ->
                val entries = vfs.list("nfs://127.0.0.1/export")
                assertEquals(listOf("movies", "readme.txt"), entries.map { it.name })
                assertTrue(entries.first().isDirectory)
                assertEquals(9L, entries[1].size)
                assertEquals("nfs://127.0.0.1/export/movies", entries[0].path)
                assertEquals("nfs://127.0.0.1/export/readme.txt", entries[1].path)
            }
        }
    }

    @Test
    fun `导出点在更浅一层时逐级回退挂载`() {
        server().use { server ->
            // MOUNT /export/movies 与 /export/movies/子目录 都应该失败，
            // 最后用 /export 挂上，再用 LOOKUP 走完剩余路径。
            vfs(server, "nfs://127.0.0.1/export/movies/子目录").use { vfs ->
                val entries = vfs.list("nfs://127.0.0.1/export/movies/子目录")
                assertEquals(listOf("c.mkv"), entries.map { it.name })
            }
        }
    }

    @Test
    fun `随机读按偏移返回`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/export").use { vfs ->
                vfs.open("nfs://127.0.0.1/export/movies/a.mkv").use { file ->
                    assertEquals(300_000L, file.size)
                    val buffer = ByteArray(1024)
                    val n = file.read(123_456, buffer, buffer.size)
                    assertEquals(1024, n)
                    // 服务端内容按 (index % 251) 生成，逐字节对照。
                    for (i in 0 until n) {
                        assertEquals(((123_456 + i) % 251).toByte(), buffer[i])
                    }
                    // 读尾部只应拿到剩余字节。
                    val tail = ByteArray(2048)
                    assertEquals(1024, file.read(300_000L - 1024, tail, tail.size))
                    // 越界返回 0。
                    assertEquals(0, file.read(300_000, buffer, buffer.size))
                }
            }
        }
    }

    @Test
    fun `中文目录名走 URL 编码`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/export").use { vfs ->
                val movies = vfs.list("nfs://127.0.0.1/export/movies")
                val sub = movies.first { it.isDirectory }
                assertEquals("子目录", sub.name)
                assertTrue(sub.path.endsWith("%E5%AD%90%E7%9B%AE%E5%BD%95"))
                assertEquals(listOf("c.mkv"), vfs.list(sub.path).map { it.name })
            }
        }
    }

    @Test
    fun `AUTH_SYS 把 uid 与 gid 送到服务端`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/export", uid = 1026, gid = 100).use { vfs ->
                vfs.list("nfs://127.0.0.1/export")
            }
            assertEquals(1, server.lastAuthFlavor)
            val auth = server.lastAuth
            assertNotNull(auth)
            assertEquals(1026, auth!!.uid)
            assertEquals(100, auth.gid)
            assertEquals("dvplayer", auth.machine)
            assertTrue(server.calls.contains("100005/3/1"))
            assertTrue(server.calls.contains("100003/3/17"))
        }
    }

    @Test
    fun `经桥接的 Range 请求拿到正确字节`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/export").use { vfs ->
                val file = vfs.open("nfs://127.0.0.1/export/movies/a.mkv")
                val bridge = VfsHttpBridge(file, "a.mkv")
                bridge.start()
                try {
                    val conn = URL(bridge.url).openConnection() as HttpURLConnection
                    conn.setRequestProperty("Range", "bytes=1000-1999")
                    assertEquals(206, conn.responseCode)
                    val body = conn.inputStream.use { it.readBytes() }
                    assertEquals(1000, body.size)
                    val expected = ByteArray(1000) { ((1000 + it) % 251).toByte() }
                    assertArrayEquals(expected, body)
                    conn.disconnect()

                    val head = URL(bridge.url).openConnection() as HttpURLConnection
                    head.requestMethod = "HEAD"
                    assertEquals(200, head.responseCode)
                    assertEquals("300000", head.getHeaderField("Content-Length"))
                    head.disconnect()
                } finally {
                    bridge.close()
                }
            }
        }
    }

    @Test
    fun `MOUNT 全失败时报找不到导出点`() {
        server().use { server ->
            vfs(server, "nfs://127.0.0.1/nope/deeper").use { vfs ->
                val error = runCatching { vfs.list("nfs://127.0.0.1/nope/deeper") }.exceptionOrNull()
                assertNotNull(error)
                assertTrue(
                    "异常信息应说明没有导出点：${error!!.message}",
                    error.message!!.contains("找不到导出点"),
                )
                assertFalse(server.calls.isEmpty())
            }
        }
    }

    @Test
    fun `列大目录会分页`() {
        server().use { server ->
            repeat(300) { i ->
                server.put("/export/big/f%03d.mkv".format(i), isDir = false, content = ByteArray(8))
            }
            vfs(server, "nfs://127.0.0.1/export").use { vfs ->
                val entries = vfs.list("nfs://127.0.0.1/export/big")
                assertEquals(300, entries.size)
                assertEquals(300, entries.map { it.name }.toSet().size)
                // 页大小 32KB / 每项约 150 字节 → 至少要两次 READDIRPLUS。
                val readdirCalls = server.calls.count { it == "100003/3/17" }
                assertTrue("READDIRPLUS 只调用了 $readdirCalls 次", readdirCalls >= 2)
            }
        }
    }
}
