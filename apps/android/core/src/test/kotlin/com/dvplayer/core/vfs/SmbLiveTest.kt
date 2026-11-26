package com.dvplayer.core.vfs

import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.auth.AuthenticationContext
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 真实 NAS 的 SMB 登录（门控，不进 CI）。
 *
 * 用来区分「设备侧 smbj 的问题」还是「smbj 与这台 Samba 的兼容性」：
 * 在 Mac 的 JVM 上跑同一套代码，靠 `SMB_LIVE=1` 打开。
 *
 * ```bash
 * SMB_LIVE=1 SMB_USER=... SMB_PASS=... \
 *   ./gradlew :core:testDebugUnitTest --tests '*SmbLiveTest*'
 * ```
 */
class SmbLiveTest {

    @Test
    fun `登录并列出共享`() {
        assumeTrue(System.getenv("SMB_LIVE") == "1")
        val host = System.getenv("SMB_HOST") ?: "10.0.0.134"
        val user = System.getenv("SMB_USER").orEmpty()
        val pass = System.getenv("SMB_PASS").orEmpty()
        val domain = System.getenv("SMB_DOMAIN").orEmpty()

        SMBClient().use { client ->
            client.connect(host).use { connection ->
                connection.authenticate(
                    AuthenticationContext(user, pass.toCharArray(), domain),
                ).use { session ->
                    println("SMB 登录成功：signing=${session.isSigningRequired}")
                    val shares = session.connectShare("影视")
                    println("连接共享成功：${shares.javaClass.simpleName}")
                    assertTrue(true)
                }
            }
        }
    }
}
