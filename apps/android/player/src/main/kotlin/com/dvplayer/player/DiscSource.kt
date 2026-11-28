package com.dvplayer.player

import android.util.Log
import java.io.File
import java.io.RandomAccessFile

/**
 * 蓝光原盘入口探测（A8）。
 *
 * 原盘的两种常见形态：
 * - **目录**：`.../SomeMovie/BDMV/index.bdmv`（用户从光盘拷出来的结构）；
 * - **ISO**：UDF 文件系统镜像，里面同样有 `BDMV/`。
 *
 * 两种都交给 mpv：它有 libbluray（`build-mpv.sh` 里静态链了 libbluray 1.5.0 +
 * libudfread 1.2.0）。**加载时用普通路径即可**——mpv 的 `bdmv_dir_stream_open`
 * 会自己识别 `.iso` 结尾的文件与含 `BDMV/MovieObject.bdmv` 的目录，验证通过后
 * 内部转成 `bluray://`（`bluray://<title>/<device>` 的 title 段不能被我们提前
 * 拼错，所以不自己拼协议地址）。**Media3 不会认原盘**，路由里原盘优先判定。
 *
 * 探测不追求完备，只做「大概率是原盘」的判定，避免把普通视频误送进
 * libbluray 打不开的路径：
 * - 目录：有 `BDMV/index.bdmv`，或路径本身就叫 `BDMV` 且里面有 `index.bdmv`；
 * - ISO：第 16 扇区有 UDF 卷识别序列（`BEA01` / `NSR02` / `NSR03`），
 *   且前 4MB 里出现 `BDMV` 目录名。
 */
object DiscSource {

    private const val TAG = "DvDisc"

    enum class Kind(val label: String) {
        ISO("ISO 镜像"),
        BDMV_DIR("BDMV 目录"),
    }

    data class Disc(
        val kind: Kind,
        /** 交给 libbluray 的根（目录形态是含 BDMV 的那一层）。 */
        val root: String,
        /** 交给内核的加载地址：普通路径，mpv 会自己识别成原盘。 */
        val playUrl: String,
    )

    /** 不是原盘返回 null。 */
    fun detect(path: String): Disc? {
        val file = File(path)
        if (!file.exists()) return null
        return if (file.isDirectory) detectDirectory(file) else detectIso(file)
    }

    private fun detectDirectory(dir: File): Disc? {
        // 用户可能给到片名目录（里面是 BDMV），也可能直接给到 BDMV。
        val root = when {
            File(dir, "BDMV/index.bdmv").isFile -> dir
            dir.name.equals("BDMV", ignoreCase = true) &&
                File(dir, "index.bdmv").isFile -> dir.parentFile ?: return null
            else -> return null
        }
        Log.i(TAG, "BDMV 目录：$root")
        return Disc(Kind.BDMV_DIR, root.absolutePath, root.absolutePath)
    }

    private fun detectIso(file: File): Disc? {
        if (!file.isFile || file.length() < (1L shl 20)) return null
        return try {
            RandomAccessFile(file, "r").use { raf ->
                if (!hasUdfSignature(raf)) return null
                if (!containsBdmv(raf)) return null
                Log.i(TAG, "ISO 原盘：${file.absolutePath}")
                Disc(Kind.ISO, file.absolutePath, file.absolutePath)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "ISO 探测失败：$file", t)
            null
        }
    }

    /**
     * UDF 卷识别序列在 32768（扇区 16）开始，每个描述符 2048 字节，
     * 结构类型 1 后面紧跟 `BEA01` / `NSR02` / `NSR03`。
     */
    private fun hasUdfSignature(raf: RandomAccessFile): Boolean {
        val offset = 32L * 1024
        if (raf.length() < offset + 8) return false
        val head = ByteArray(8)
        raf.seek(offset)
        raf.readFully(head)
        val id = String(head, 1, 5, Charsets.US_ASCII)
        return id == "BEA01" || id == "NSR02" || id == "NSR03"
    }

    /** 目录项里的文件标识是 ASCII 文件名，扫前 4MB 找 `BDMV` 足够可靠。 */
    private fun containsBdmv(raf: RandomAccessFile): Boolean {
        val length = minOf(raf.length(), 4L shl 20).toInt()
        if (length < 4) return false
        val buffer = ByteArray(length)
        raf.seek(0)
        raf.readFully(buffer)
        val needle = "BDMV".toByteArray(Charsets.US_ASCII)
        var i = 0
        val last = buffer.size - needle.size
        while (i <= last) {
            var j = 0
            while (j < needle.size && buffer[i + j] == needle[j]) j++
            if (j == needle.size) return true
            i++
        }
        return false
    }
}
