package com.dvplayer.app

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.dvplayer.core.MediaHub
import com.dvplayer.core.SourceConfig
import com.dvplayer.core.config.SourceStore
import com.dvplayer.design.DvTheme
import com.dvplayer.ui.phone.player.PlayerDemo
import com.dvplayer.ui.phone.player.PlayerErrorScreen
import com.dvplayer.ui.phone.player.PlayerLoadingScreen
import com.dvplayer.ui.phone.player.PlayerPanel
import com.dvplayer.ui.phone.player.PlayerScreen
import com.dvplayer.ui.phone.player.PlayerUiModel
import com.dvplayer.ui.phone.player.PlayerUiModelFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 手机播放页。
 *
 * 两种进入方式：
 * - 演示（默认）：用 [PlayerDemo] 的假数据，用来验收布局。
 * - 真实条目：`--es item <sourceId:itemId>`，从 `SourceStore` 读源配置，登录后
 *   取 `detail / playSource / mediaInfo` 再映射成同一个 UI 模型。
 *
 *   adb shell am start -n com.dvplayer.app/.PlaybackActivity \
 *       --es item local-smoke:/path/to/movie.mkv
 *
 *   调试时还可以用 `--es config '<SourceConfig JSON>'` 临时加一个源（不落盘）。
 *
 * 布局验收参数：`--es mode landscape|portrait|info|menu|audio|subtitle|episodes`
 * 和 `--ez no_hide true`（关掉 3 秒自动淡出）。
 */
class PlaybackActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        val mode = intent.getStringExtra("mode").orEmpty()
        val landscape = when (mode) {
            "portrait" -> false
            "landscape" -> true
            else -> resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }

        // 截图 / 验收时给一个确定的方向；正常进入跟随重力。
        requestedOrientation = when (mode) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }

        applySystemBars(hide = landscape)

        // 面板可以单独指定，这样横屏（固定 landscape）也能截到面板。
        val panelName = intent.getStringExtra("panel") ?: mode
        val panel = when (panelName) {
            "info" -> PlayerPanel.Info
            "audio" -> PlayerPanel.Audio
            "subtitle" -> PlayerPanel.Subtitle
            "episodes" -> PlayerPanel.Episodes
            else -> PlayerPanel.None
        }
        val noHide = intent.getBooleanExtra("no_hide", false)
        val menuOpen = mode == "menu" || intent.getBooleanExtra("menu", false)
        val itemId = intent.getStringExtra("item")?.takeIf { it.isNotBlank() }

        setContent {
            DvTheme {
                if (itemId == null) {
                    PlayerScreen(
                        model = if (landscape) PlayerDemo.film else PlayerDemo.episode,
                        onBack = { finish() },
                        initialPanel = panel,
                        initialMenuOpen = menuOpen,
                        forceLandscape = landscape,
                        autoHide = !noHide,
                    )
                } else {
                    RealPlayback(
                        itemId = itemId,
                        landscape = landscape,
                        panel = panel,
                        menuOpen = menuOpen,
                        autoHide = !noHide,
                        onBack = { finish() },
                    )
                }
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applySystemBars(newConfig.orientation == Configuration.ORIENTATION_LANDSCAPE)
    }

    private fun applySystemBars(hide: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (hide) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
            controller.isAppearanceLightStatusBars = false
        }
    }

    /** 横屏进沉浸后，第一次点画面唤出的是控制层，不是系统栏。 */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
            applySystemBars(hide = true)
        }
    }

    // —— 真实条目 ——

    private sealed interface Load {
        data object Loading : Load
        data class Ready(val model: PlayerUiModel) : Load
        data class Failed(val message: String) : Load
    }

    @Composable
    private fun RealPlayback(
        itemId: String,
        landscape: Boolean,
        panel: PlayerPanel,
        menuOpen: Boolean,
        autoHide: Boolean,
        onBack: () -> Unit,
    ) {
        val state by produceState<Load>(Load.Loading, itemId) {
            value = withContext(Dispatchers.IO) { load(itemId) }
        }

        when (val current = state) {
            Load.Loading -> PlayerLoadingScreen()
            is Load.Failed -> PlayerErrorScreen(current.message, onBack)
            is Load.Ready -> PlayerScreen(
                model = current.model,
                onBack = onBack,
                initialPanel = panel,
                initialMenuOpen = menuOpen,
                forceLandscape = landscape,
                autoHide = autoHide,
            )
        }
    }

    private fun load(itemId: String): Load {
        val hub = MediaHub.open() ?: return Load.Failed("核心不可用：MediaHub.open 返回 null")
        return try {
            hub.use { media ->
                val configs = resolveConfigs()
                if (configs.isEmpty()) {
                    return Load.Failed(
                        "还没有配置源。先用 --es config '<SourceConfig JSON>' 启动，\n" +
                            "或在设置页里添加源。",
                    )
                }

                val connections = media.addMany(configs)
                val okIds = connections.filter { it.ok }.map { it.id }.toSet()
                if (okIds.isEmpty()) {
                    val detail = connections.joinToString("\n") { "${it.name}：${it.error ?: "登录失败"}" }
                    return Load.Failed("所有源都连不上：\n$detail")
                }

                val sourceId = itemId.substringBefore(':', "")
                if (sourceId.isNotEmpty() && sourceId !in okIds) {
                    val failed = connections.firstOrNull { it.id == sourceId }
                    return Load.Failed("源 $sourceId 未连上：${failed?.error ?: "不在配置里"}")
                }

                val play = media.playSource(itemId)
                val detail = runCatching { media.detail(itemId) }.getOrNull()
                val info = runCatching { media.mediaInfo(itemId) }.getOrNull()
                val sources = runCatching { media.sources() }.getOrDefault(emptyList())
                val source = sources.firstOrNull { it.id == sourceId }

                val engine = intent.getStringExtra("engine")
                    ?.takeIf { it == "mpv" || it == "Media3" }
                    ?: "mpv"

                Load.Ready(
                    PlayerUiModelFactory.from(
                        detail = detail,
                        play = play,
                        info = info,
                        sourceName = source?.name ?: sourceId.ifEmpty { "未知源" },
                        sourceKind = source?.kind ?: detail?.kind ?: "",
                        subtitle = subtitleOf(detail),
                        engine = engine,
                    ),
                )
            }
        } catch (err: Exception) {
            Load.Failed("${err.javaClass.simpleName}：${err.message ?: "未知错误"}")
        }
    }

    /** `SourceStore` + 命令行临时源；同 id 时命令行优先。 */
    private fun resolveConfigs(): List<SourceConfig> {
        val stored = SourceStore(this).load()
        val extra = intent.getStringExtra("config")?.let { SourceStore.parse(it) }
        val merged = buildList {
            addAll(stored)
            extra?.let { injected ->
                removeAll { it.id == injected.id }
                add(injected)
            }
        }
        return merged.map {
            if (it.dataDir.isBlank()) it.copy(dataDir = filesDir.absolutePath) else it
        }
    }

    private fun subtitleOf(detail: com.dvplayer.core.MediaDetail?): String? {
        val season = detail?.seasonCount?.takeIf { it > 1 }?.let { "共 $it 季" }
        val year = detail?.releaseDate?.take(4)?.takeIf { it.length == 4 }
        return listOfNotNull(season, year).joinToString(" · ").ifBlank { null }
    }
}
