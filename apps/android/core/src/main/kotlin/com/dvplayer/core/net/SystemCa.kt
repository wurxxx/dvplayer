package com.dvplayer.core.net

import android.content.Context
import android.util.Log
import java.io.File

/**
 * 内置的 Mozilla CA 包（`assets/cacert.pem`）。
 *
 * 为什么不用系统信任库：Android 的 CA 在 conscrypt 的 APEX 里，native 的
 * mbedTLS 既读不到、也没有默认路径，不显式给文件就会「所有 https 都失败」。
 * 打成 APK 里一份（约 200KB）跨 Android 版本一致，也便于审计。
 *
 * 用法：需要校验时把 [ensure] 的路径交给 mpv 的 `tls-ca-file`。
 * 自签名源仍然靠源级开关关掉校验，不要把它的证书混进这份公共包。
 */
object SystemCa {

    const val ASSET = "cacert.pem"

    private const val TAG = "DvTls"

    @Volatile
    private var cached: File? = null

    /**
     * 把 asset 复制到 `filesDir/ca/` 并返回文件。进程内只复制一次；
     * APK 升级后 asset 变化，下一次进程启动会覆盖。
     */
    fun ensure(context: Context): File {
        cached?.takeIf { it.exists() }?.let { return it }
        synchronized(this) {
            cached?.takeIf { it.exists() }?.let { return it }
            val dir = File(context.filesDir, "ca").apply { mkdirs() }
            val target = File(dir, ASSET)
            val temp = File(dir, "$ASSET.tmp")
            context.assets.open(ASSET).use { input ->
                temp.outputStream().use { output -> input.copyTo(output) }
            }
            if (target.exists() && target.length() == temp.length()) {
                temp.delete()
            } else {
                target.delete()
                if (!temp.renameTo(target)) {
                    throw IllegalStateException("CA 包移动失败：$temp -> $target")
                }
            }
            Log.i(TAG, "CA 包就绪：${target.absolutePath}（${target.length()} 字节）")
            cached = target
            return target
        }
    }
}
