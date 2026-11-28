package com.dvplayer.core.credential

import org.junit.Assert.assertEquals
import org.junit.Test

class CredentialScopeTest {

    @Test
    fun `SMB 默认端口是 445`() {
        assertEquals(
            "smb://10.0.0.134:445",
            CredentialScope.of("smb://10.0.0.134/影视/电影.mkv"),
        )
    }

    @Test
    fun `显式端口优先`() {
        assertEquals(
            "smb://nas.local:1445",
            CredentialScope.of("smb://nas.local:1445/share/a.mkv", defaultPort = 445),
        )
    }

    @Test
    fun `https 默认 443`() {
        assertEquals(
            "https://dav.example.com:443",
            CredentialScope.of("https://dav.example.com/remote.php/dav/files/u/"),
        )
    }

    @Test
    fun `http 默认 80`() {
        assertEquals("http://127.0.0.1:8099", CredentialScope.of("http://127.0.0.1:8099/a.mp4"))
    }

    @Test
    fun `去掉路径与查询串`() {
        assertEquals(
            "https://dav.example.com:8443",
            CredentialScope.of("https://dav.example.com:8443/a/b?x=1#frag"),
        )
    }

    @Test
    fun `去掉 userinfo`() {
        assertEquals(
            "smb://nas:445",
            CredentialScope.of("smb://wurxx:x@nas/share"),
        )
    }

    @Test
    fun `不是 URL 时原样返回`() {
        assertEquals("/sdcard/a.mkv", CredentialScope.of("/sdcard/a.mkv"))
        assertEquals("dav.example.com", CredentialScope.of("dav.example.com"))
    }

    @Test
    fun `未知协议且没端口时只保留主机`() {
        assertEquals("ftp://nas", CredentialScope.of("ftp://nas/dir"))
    }

    @Test
    fun `日志脱敏不留下用户名密码`() {
        assertEquals(
            "smb://nas/share",
            CredentialStore.redactScope("smb://user:x@nas/share"),
        )
        assertEquals("https://dav:443", CredentialStore.redactScope("https://dav:443"))
    }
}
