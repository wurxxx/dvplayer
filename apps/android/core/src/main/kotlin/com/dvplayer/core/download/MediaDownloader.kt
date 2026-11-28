package com.dvplayer.core.download

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit

/**
 * 下载到应用私有目录（A10）。
 *
 * 目标目录是 `context.filesDir/downloads`：Android 11+ 的 external app 专属目录
 * 在部分 ROM 上 `adb` / 播放器读不到（见 M2-ANDROID 的存储结论），内部目录最稳。
 *
 * 支持断点续传：先写 `<name>.part`，下次启动时用 `Range: bytes=<已下载>-` 续；
 * 服务器不回 206（不支持 Range）就从头重下。完成后再改名成正式文件。
 */
class MediaDownloader(
    private val dir: File,
) {

    private val tag = "DvDownload"

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * 下载 [url] 为 [name]。返回完成后的文件。
     * [onProgress] 回调 (已下载字节, 总字节或 -1)。
     */
    fun download(
        url: String,
        name: String,
        headers: Map<String, String> = emptyMap(),
        onProgress: ((Long, Long) -> Unit)? = null,
    ): File {
        require(name.isNotEmpty() && !name.contains('/')) { "非法文件名：$name" }
        dir.mkdirs()
        val part = File(dir, "$name.part")
        val target = File(dir, name)
        var offset = if (part.isFile) part.length() else 0L

        val request = Request.Builder()
            .url(url)
            .apply {
                headers.forEach { (k, v) -> header(k, v) }
                if (offset > 0) header("Range", "bytes=$offset-")
            }
            .build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("下载 $url -> HTTP ${response.code}")
            }
            val append = offset > 0 && response.code == 206
            if (!append) offset = 0
            val body = response.body ?: throw IllegalStateException("下载 $url 无响应体")
            val total = body.contentLength().let { if (it >= 0) it + offset else -1L }
            var done = offset

            FileOutputStream(part, append).use { out ->
                val buffer = ByteArray(128 * 1024)
                body.byteStream().use { input ->
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        done += read
                        onProgress?.invoke(done, total)
                    }
                }
            }
            Log.i(tag, "下载完成：$url -> $target（$done 字节，续传=$append）")
        }

        if (target.exists()) target.delete()
        if (!part.renameTo(target)) {
            throw IllegalStateException("改名失败：$part -> $target")
        }
        return target
    }
}
