package com.dvplayer.app

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import com.dvplayer.core.CoreException
import com.dvplayer.core.DvCore
import com.dvplayer.core.MediaHub
import com.dvplayer.core.SourceConfig
import com.dvplayer.core.SourceConnection
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A3 数据层冒烟：Kotlin → JNI → Rust 核心。
 *
 *   adb shell am start -n com.dvplayer.app/.CoreSmokeActivity \
 *       --es dir /data/user/0/com.dvplayer.app/files
 *
 * 有视频文件才有内容可查；目录为空时只验证「建连 → 库列表 → 空条目」这条链。
 * 结果同时写 logcat（tag `DvCoreSmoke`）和屏幕，最后一行 `RESULT PASS|FAIL`。
 *
 * 这个页面只用于验收，正式手机界面起来后可以删。
 */
class CoreSmokeActivity : Activity() {

    private lateinit var output: TextView
    private val lines = StringBuilder()
    private var passed = 0
    private var failed = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        output = TextView(this).apply {
            textSize = 11f
            setPadding(24, 24, 24, 24)
            typeface = android.graphics.Typeface.MONOSPACE
        }
        setContentView(ScrollView(this).apply {
            addView(output, android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT)
            isFillViewport = true
        })

        val dir = intent.getStringExtra("dir")
            ?: File(filesDir, "medias").absolutePath
        val doviFile = intent.getStringExtra("dovi")

        Thread({ runSmoke(dir, doviFile) }, "core-smoke").start()
    }

    private fun runSmoke(dir: String, doviFile: String?) {
        try {
            smoke(dir, doviFile)
        } catch (_: SmokeAbort) {
            // step() 已经记过失败，这里只负责收尾。
        } catch (err: Throwable) {
            fail("未捕获异常", err.toString())
        }
        finishReport()
    }

    private fun smoke(dir: String, doviFile: String?) {
        line("目录：$dir")
        line("files 里：${File(dir).list()?.joinToString().orEmpty().ifEmpty { "（空）" }}")

        // 1. 不需要句柄的入口。
        step("version") {
            DvCore.version.also { if (it.startsWith("unavailable")) error(it) }
        }
        step("sourceKinds") { DvCore.sourceKinds().joinToString(",") }

        // 2. 聚合句柄：建 → 登录 → 库 → 条目 → 详情 → 播放源 → 记录。
        val hub = MediaHub.open() ?: run {
            fail("MediaHub.open", "返回 null")
            throw SmokeAbort("MediaHub.open", IllegalStateException("hub 建不出来"))
        }
        hub.use {
            val config = SourceConfig(
                id = "local-smoke",
                name = "本地冒烟",
                kind = "local",
                base = dir,
                dataDir = filesDir.absolutePath,
            )

            step("hub.add") { it.add(config).let { info -> "${info.name}/${info.kind}" } }

            val libraries = step("hub.libraries") {
                it.libraries().also { list -> require(list.isNotEmpty()) { "本地源应有一个库" } }
            }
            val libraryId = libraries[0].id

            val page = step("hub.items") {
                it.items(libraryId, pageSize = 100).also { p -> line("    共 ${p.total} 条") }
            }

            if (page.items.isEmpty()) {
                line("  （目录里没有视频文件，跳过条目相关步骤）")
            } else {
                val item = page.items.first()
                line("    首条：${item.id} / ${item.title} / ${item.kind}")

                var posterPath: String? = null

                step("hub.detail") {
                    it.detail(item.id).also { detail ->
                        posterPath = detail.posterPath
                        require(detail.title.isNotEmpty()) { "detail.title 为空" }
                    }.let { detail -> "${detail.title} kind=${detail.kind}" }
                }

                step("hub.playSource") {
                    it.playSource(item.id).also { src ->
                        require(src.url.isNotEmpty()) { "播放地址为空" }
                    }.let { src -> "url=${src.url.take(90)} direct=${src.isDirect} disc=${src.disc}" }
                }

                step("hubMediaInfo") {
                    it.mediaInfo(item.id).also { info ->
                        require(info.path != null) { "mediaInfo.path 为空" }
                    }.let { info ->
                        val v = info.video
                        "%s %sx%s %s".format(
                            v?.codec ?: "?",
                            v?.width ?: "?",
                            v?.height ?: "?",
                            v?.colorRange ?: "SDR",
                        )
                    }
                }

                posterPath?.let { path ->
                    step("hub.imageSource") {
                        it.imageSource(path).let { img -> "url=${img.url.take(70)}" }
                    }
                }

                // 观看记录：先报进度，再从 records 里读回来（hub 会补上源前缀）。
                step("hub.reportProgress→records") {
                    it.reportProgress(item.id, 30, 1800)
                    val records = it.records()
                    require(records.any { r -> r.itemId == item.id }) {
                        "records 里没有刚上报的条目：${records.map { r -> r.itemId }}"
                    }
                    "records=${records.size} 首条=${records.first().title}"
                }

                step("hub.setWatched(false)") {
                    it.setWatched(item.id, false)
                    "已取消看到"
                }

                step("hub.removeRecord") {
                    it.removeRecord(item.id)
                    "已移除记录"
                }

                step("hub.search") {
                    val needle = item.title.take(4)
                    it.search(needle).let { result ->
                        "关键词“$needle”命中 ${result.items.size}，失败源 ${result.failed.size}"
                    }
                }

                step("hub.children") {
                    it.children(item.id, pageSize = 100).let { kids -> "子条目 ${kids.total} 条" }
                }

                step("hub.people") { "演职员 ${it.people(item.id).size} 人" }
                step("hub.genres") { "风格 ${it.genres(libraryId).size} 个" }
                step("hub.favorites") {
                    it.favorites().let { fav -> "收藏 ${fav.total} 条" }
                }

                // 不支持的操作应返回 ok=false，而不是崩溃。
                step("错误路径（detail 不存在）") {
                    val err = runCatching { it.detail("local-smoke:no-such-item") }.exceptionOrNull()
                    require(err is CoreException) { "期望 CoreException，实际 $err" }
                    "CoreException：${err.message?.take(40)}"
                }
            }
        }

        // 3. 流式建连：两个源，回调必须逐条回来。
        val streamHub = MediaHub.open()
        if (streamHub == null) {
            fail("hub.addManyStream", "第二个 MediaHub.open() 返回 null")
        } else streamHub.use { hub ->
            val configs = listOf(
                SourceConfig("stream-a", "流式 A", "local", dir, dataDir = filesDir.absolutePath),
                SourceConfig("stream-b", "流式 B", "local", dir, dataDir = filesDir.absolutePath),
            )
            val seen = mutableListOf<SourceConnection>()
            val latch = CountDownLatch(1)
            step("hub.addManyStream") {
                val all = hub.addManyStream(configs) { conn ->
                    synchronized(seen) { seen += conn }
                    if (seen.size == configs.size) latch.countDown()
                }
                latch.await(5, TimeUnit.SECONDS)
                synchronized(seen) {
                    require(seen.size == configs.size) { "回调 ${seen.size}/${configs.size}" }
                }
                "回调 ${seen.size} 条，返回 ${all.size} 条，全部成功=${all.all { c -> c.ok }}"
            }
        }

        // 4. DV FEL/MEL 探测（有样片时才跑）。
        if (!doviFile.isNullOrEmpty()) {
            step("probeDovi") {
                val info = DvCore.probeDovi(doviFile)
                if (info == null) "不是 P7（无 RPU）"
                else "P${info.profile} ${info.elType.uppercase()} disableResidual=${info.disableResidual}"
            }
        }
    }

    private fun finishReport() {
        val ok = failed == 0
        line("")
        line(if (ok) "RESULT PASS  ($passed 步)" else "RESULT FAIL  ($passed 通过 / $failed 失败)")
        Log.i(TAG, if (ok) "RESULT PASS ($passed)" else "RESULT FAIL ($passed/$failed)")
        runOnUiThread { output.text = lines.toString() }
    }

    private fun <T> step(name: String, block: () -> T): T {
        val start = System.nanoTime()
        return try {
            val value = block()
            val ms = (System.nanoTime() - start) / 1_000_000
            passed++
            line("✓ $name [${ms}ms] $value")
            value
        } catch (err: Throwable) {
            fail(name, err.message ?: err.javaClass.simpleName)
            throw SmokeAbort(name, err)
        }
    }

    /** 步骤失败后不继续后面的链路（后面的都依赖前一步的句柄）。 */
    private class SmokeAbort(name: String, cause: Throwable) :
        RuntimeException("冒烟在 $name 中止", cause)

    private fun fail(name: String, message: String) {
        failed++
        line("✗ $name：$message")
        Log.e(TAG, "✗ $name：$message")
    }

    private fun line(text: String) {
        Log.i(TAG, text)
        synchronized(lines) { lines.append(text).append('\n') }
    }

    companion object {
        private const val TAG = "DvCoreSmoke"
    }
}
