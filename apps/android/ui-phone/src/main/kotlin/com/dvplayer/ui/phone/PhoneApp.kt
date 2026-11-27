package com.dvplayer.ui.phone

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvScaffold
import com.dvplayer.design.DvTab
import com.dvplayer.design.DvTheme
import com.dvplayer.ui.phone.data.PhoneRepoHolder
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.screens.AddSourceDialog
import com.dvplayer.ui.phone.screens.CategoryScreen
import com.dvplayer.ui.phone.screens.DetailScreen
import com.dvplayer.ui.phone.screens.SearchScreen
import com.dvplayer.ui.phone.screens.SettingsScreen
import com.dvplayer.ui.phone.screens.SourceHomeScreen
import com.dvplayer.ui.phone.screens.SourceListScreen
import com.dvplayer.ui.phone.screens.WatchScreen
import com.dvplayer.ui.phone.ui.LocalRepo
import kotlinx.coroutines.launch

/** 媒体 tab 里的页面栈。 */
sealed interface PhoneRoute {
    data object Sources : PhoneRoute
    data class SourceHome(val sourceId: String) : PhoneRoute
    data class Category(val sourceId: String, val libraryId: String, val title: String) : PhoneRoute
    data class Detail(val itemId: String) : PhoneRoute
}

private val PhoneTabs = listOf(
    DvTab("媒体", DvGlyph.Media),
    DvTab("观看", DvGlyph.Watch),
    DvTab("搜索", DvGlyph.Search),
    DvTab("设置", DvGlyph.Settings),
)

/**
 * 手机端入口。
 *
 * 四个 tab：媒体（源列表 → 源首页 → 分类 → 详情）/ 观看 / 搜索 / 设置。
 * 媒体 tab 内部是栈，切到别的 tab 再回来会停在原处。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
/**
 * [onPlay] 第二个参数是「这部剧」的条目 id（剧集播放时用来取同季的其他集）；
 * 电影没有父级，传 null。
 */
fun PhoneApp(onPlay: (String, String?) -> Unit = { _, _ -> }) {
    val context = LocalContext.current
    val repo = remember { PhoneRepository(context) }
    // 播放页（另一个 Activity）取剧照要复用这个仓库的位图缓存。
    LaunchedEffect(repo) { PhoneRepoHolder.repo = repo }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { repo.connect() }

    var tab by remember { mutableStateOf(0) }
    val stack = remember { mutableStateListOf<PhoneRoute>(PhoneRoute.Sources) }
    var addingSource by remember { mutableStateOf(false) }
    // 观看 tab 每次切进来都重新拉：收藏 / 播放进度是别的页面改的，
    // 停留在 tab 里的状态会过期。
    var watchRevision by remember { mutableIntStateOf(0) }

    // 键盘弹起时收起浮空 tab：它要么挡住键盘，要么浮在键盘上沿，两种都不好看。
    // 用 isImeVisible 而不是量 ime 高度——API 28 上 ime inset 拿不到高度。
    val keyboardOpen = WindowInsets.isImeVisible

    // 源首页 / 详情页整页是大图：从屏幕最顶上铺下来，不能有那 12dp 呼吸。
    val topRoute = stack.lastOrNull()
    val heroPage = tab == 0 &&
        (topRoute is PhoneRoute.SourceHome || topRoute is PhoneRoute.Detail)

    BackHandler(enabled = tab == 0 && stack.size > 1) {
        stack.removeAt(stack.lastIndex)
    }
    BackHandler(enabled = tab != 0) {
        tab = 0
    }

    DvTheme {
        CompositionLocalProvider(LocalRepo provides repo) {
            SystemBarIcons(dark = DvTheme.palette.isDark)
            DvScaffold(
                tabs = PhoneTabs,
                selectedTab = tab,
                onTab = { next ->
                    if (next == 1 && tab != 1) watchRevision += 1
                    tab = next
                },
                showTab = !keyboardOpen,
                backdropKey = tab to stack.lastOrNull(),
                topInset = !heroPage,
                // 搜索照参考图单独做成右侧的圆形按钮，胶囊里只留三个页签。
                detachedTab = 2,
            ) {
                when (tab) {
                    0 -> MediaHost(
                        repo = repo,
                        stack = stack,
                        onPlay = onPlay,
                        onAddSource = { addingSource = true },
                    )
                    1 -> WatchScreen(
                        repo = repo,
                        revision = watchRevision,
                        onPlay = onPlay,
                        onOpenDetail = { stack.add(PhoneRoute.Detail(it)); tab = 0 },
                    )
                    2 -> SearchScreen(
                        repo = repo,
                        onOpenDetail = { stack.add(PhoneRoute.Detail(it)); tab = 0 },
                    )
                    else -> SettingsScreen(
                        repo = repo,
                        onAddSource = { addingSource = true },
                        onReconnect = { scope.launch { repo.reconnect(it) } },
                    )
                }
            }

            if (addingSource) {
                AddSourceDialog(
                    onDismiss = { addingSource = false },
                    onConfirm = { config ->
                        addingSource = false
                        repo.addSource(config)
                        scope.launch { repo.connect() }
                    },
                )
            }
        }
    }
}

/**
 * 系统栏图标颜色跟着内容页深浅走。
 *
 * 窗口是 edge-to-edge 的，状态栏 / 导航栏底色由 DvScaffold 自己画；图标只有黑白两档，
 * 浅色背景必须切黑图标，否则白图标压在浅底上等于消失。
 */
@Composable
private fun SystemBarIcons(dark: Boolean) {
    val view = LocalView.current
    val windowBackground = DvTheme.palette.background
    if (view.isInEditMode) return
    SideEffect {
        val window = (view.context as? Activity)?.window ?: return@SideEffect
        val controller = WindowCompat.getInsetsController(window, view)
        controller.isAppearanceLightStatusBars = !dark
        controller.isAppearanceLightNavigationBars = !dark
        // 键盘弹出时导航栏会临时回来；透明的话露出的是输入法自己那块黑底，
        // 所以给导航栏一个和页面同色不透明的底。
        window.navigationBarColor = windowBackground.toArgb()
    }
}

@Composable
private fun MediaHost(
    repo: PhoneRepository,
    stack: MutableList<PhoneRoute>,
    onPlay: (String, String?) -> Unit,
    onAddSource: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val route = stack.last()

    when (route) {
        is PhoneRoute.Sources -> SourceListScreen(
            repo = repo,
            onOpenSource = { stack.add(PhoneRoute.SourceHome(it)) },
            onReconnect = { scope.launch { repo.reconnect(it) } },
            onAddSource = onAddSource,
        )

        is PhoneRoute.SourceHome -> SourceHomeScreen(
            repo = repo,
            sourceId = route.sourceId,
            onBack = { stack.removeAt(stack.lastIndex) },
            onPlay = onPlay,
            onOpenCategory = { libId, title -> stack.add(PhoneRoute.Category(route.sourceId, libId, title)) },
            onOpenDetail = { stack.add(PhoneRoute.Detail(it)) },
        )

        is PhoneRoute.Category -> CategoryScreen(
            repo = repo,
            sourceId = route.sourceId,
            libraryId = route.libraryId,
            title = route.title,
            onBack = { stack.removeAt(stack.lastIndex) },
            onOpenDetail = { stack.add(PhoneRoute.Detail(it)) },
        )

        is PhoneRoute.Detail -> DetailScreen(
            repo = repo,
            itemId = route.itemId,
            onBack = { stack.removeAt(stack.lastIndex) },
            onPlay = onPlay,
        )
    }
}
