package com.dvplayer.core.vfs

import android.util.Log
import android.util.Xml
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * WebDAV 浏览（A9）。
 *
 * 只做「列目录」这一件事：`PROPFIND` + `Depth: 1` + 基本认证。拿到条目后
 * 播放不需要额外实现——`VfsEntry.path` 就是 `http(s)://` 地址，mpv 与 Media3
 * 都能直接起播、Range seek。SMB / NFS 需要各自的 DataSource 或 libnfs，
 * 由后续实现同一接口。
 *
 * 用 OkHttp 而不是 `HttpURLConnection`：Android 的实现只允许
 * OPTIONS/GET/HEAD/POST/PUT/DELETE/TRACE/PATCH，`setRequestMethod("PROPFIND")`
 * 直接抛 `ProtocolException`；OkHttp 允许自定义方法。
 */
class DavVfs(
    private val baseUrl: String,
    private val user: String? = null,
    private val password: String? = null,
) : Vfs {

    private val tag = "DvDav"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    override fun list(dir: String): List<VfsEntry> {
        val url = dir.toHttpUrl()
        val builder = Request.Builder()
            .url(url)
            .method("PROPFIND", PROPFIND_BODY.toRequestBody(XML_TYPE))
            .header("Depth", "1")
        if (user != null) {
            builder.header("Authorization", Credentials.basic(user, password.orEmpty()))
        }
        client.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("PROPFIND $dir -> HTTP ${response.code}")
            }
            val body = response.body ?: throw IllegalStateException("PROPFIND $dir 无响应体")
            val entries = body.byteStream().use { parse(it, url) }
            Log.i(tag, "PROPFIND $dir -> ${entries.size} 项")
            return entries
        }
    }

    /** 解析 `207 Multi-Status`，跳过请求地址自身对应的那一条。 */
    private fun parse(input: InputStream, requestUrl: HttpUrl): List<VfsEntry> {
        val parser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(input, null)

        val result = ArrayList<VfsEntry>()
        var href: String? = null
        var size = -1L
        var modified = -1L
        var isDirectory = false
        var inResponse = false

        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            when (parser.eventType) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "response" -> {
                        inResponse = true
                        href = null
                        size = -1
                        modified = -1
                        isDirectory = false
                    }
                    "href" -> if (inResponse) href = parser.nextText().trim()
                    "getcontentlength" -> if (inResponse) {
                        size = parser.nextText().trim().toLongOrNull() ?: -1
                    }
                    "getlastmodified" -> if (inResponse) {
                        modified = parseHttpDate(parser.nextText().trim())
                    }
                    "collection" -> isDirectory = true
                }
                XmlPullParser.END_TAG -> if (parser.name == "response" && inResponse) {
                    inResponse = false
                    // href 可能是绝对 URL，也可能是以 / 开头的服务器路径，
                    // HttpUrl.resolve 两种都能接。
                    val resolved = href?.let { requestUrl.resolve(it) }
                    if (resolved == null) continue
                    if (resolved.encodedPath.trimEnd('/') ==
                        requestUrl.encodedPath.trimEnd('/')
                    ) {
                        continue
                    }
                    // 目录 URL 以 / 结尾，pathSegments 的最后一个元素是空串。
                    val name = resolved.pathSegments.lastOrNull { it.isNotEmpty() }.orEmpty()
                    if (name.isEmpty()) continue
                    val path = resolved.toString()
                    result += VfsEntry(
                        name = name,
                        path = if (isDirectory && !path.endsWith("/")) "$path/" else path,
                        isDirectory = isDirectory,
                        size = size,
                        lastModifiedMs = modified,
                    )
                }
            }
            parser.next()
        }
        return result.sortedWith(compareByDescending<VfsEntry> { it.isDirectory }.thenBy { it.name })
    }

    private fun parseHttpDate(value: String): Long = runCatching {
        SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT")
        }.parse(value)?.time ?: -1L
    }.getOrDefault(-1L)

    private companion object {
        val XML_TYPE = "application/xml; charset=utf-8".toMediaType()

        val PROPFIND_BODY = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:displayname/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:resourcetype/>
              </d:prop>
            </d:propfind>
        """.trimIndent()
    }
}
