package com.dvplayer.core.credential

/**
 * 凭据的作用域：`scheme://host:port`，不带路径与查询串。
 *
 * 同一台 NAS 上的不同共享 / 目录共用一个账号，所以按主机存；换共享不用
 * 重输密码。端口缺省时补常见值（SMB 445、HTTP 80、HTTPS 443）。
 *
 * 不用 `java.net.URI` 的 host 解析直接失败就原样返回：SMB 的路径里常有
 * 空格、括号与中文，URI 可能抛异常，但凭据作用域只需要前半段。
 */
object CredentialScope {

    fun of(url: String, defaultPort: Int = 0): String {
        val scheme = url.substringBefore("://", "").lowercase()
        if (scheme.isEmpty()) return url
        val rest = url.substringAfter("://")
        val authority = rest.substringBefore('/').substringBefore('?').substringBefore('#')
        // 去掉可能存在的 userinfo（`user:pass@host`）。
        val hostPort = authority.substringAfterLast('@')
        if (hostPort.isEmpty()) return url
        val host = hostPort.substringBefore(':').ifEmpty { return url }
        val explicitPort = hostPort.substringAfter(':', "").toIntOrNull() ?: 0
        val port = if (explicitPort > 0) {
            explicitPort
        } else if (defaultPort > 0) {
            defaultPort
        } else {
            when (scheme) {
                "http" -> 80
                "https" -> 443
                "smb" -> 445
                else -> 0
            }
        }
        return if (port > 0) "$scheme://$host:$port" else "$scheme://$host"
    }
}
