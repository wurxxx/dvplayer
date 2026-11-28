package com.dvplayer.core.vfs.nfs

import com.dvplayer.core.vfs.NfsVfs
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 真实 NFS 服务器的登录 / 列表 / 随机读（门控，不进 CI）。
 *
 * 协议层已经由 [FakeNfsServer] 覆盖，这里用真服务器校准我们对协议的理解：
 * 真实句柄长度、AUTH_SYS 身份、`exports` 的写法、`READDIRPLUS` 的分页行为。
 *
 * ```bash
 * NFS_LIVE=1 NFS_URL=nfs://10.0.0.134/fs/1000/nfs \
 *   ./gradlew :core:testDebugUnitTest --tests '*NfsLiveTest*'
 * ```
 */
class NfsLiveTest {

    @Test
    fun `列出导出并读一个文件`() {
        assumeTrue(System.getenv("NFS_LIVE") == "1")
        val url = System.getenv("NFS_URL") ?: "nfs://10.0.0.134/fs/1000/nfs"
        NfsVfs(url).use { vfs ->
            val entries = vfs.list(url)
            println("NFS 列表 ${entries.size} 项：$url")
            entries.take(12).forEach {
                println("  ${if (it.isDirectory) "D" else "F"} ${it.name} size=${it.size}")
            }
            assertTrue("导出目录为空也可以，但至少要能列", entries.size >= 0)
            val file = entries.firstOrNull { !it.isDirectory }
            if (file != null) {
                vfs.open(file.path).use { f ->
                    val buffer = ByteArray(4096)
                    val n = f.read(0, buffer, buffer.size)
                    println("读取 ${file.name}：$n 字节，size=${f.size}")
                    assertTrue("前 4KB 应能读到", n > 0)
                }
            } else {
                println("导出里没有文件，跳过读")
            }
        }
    }
}
