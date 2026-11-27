package com.dvplayer.ui.phone.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.ListQuery
import com.dvplayer.core.MediaDetail
import com.dvplayer.core.MediaItem
import com.dvplayer.core.MediaLibrary
import com.dvplayer.core.PlayRecord
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.design.DvOnImage
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.ui.HeroBackdrop
import com.dvplayer.ui.phone.ui.cleanTitle
import com.dvplayer.ui.phone.ui.RemoteImage
import com.dvplayer.ui.phone.ui.PosterCard
import com.dvplayer.ui.phone.ui.ScreenHeader
import com.dvplayer.ui.phone.ui.SectionHeader
import com.dvplayer.ui.phone.ui.WideCard

/**
 * 单个源的首页。
 *
 * 四段：最新入库（hero）→ 继续观看 → 我的媒体（库入口）→ 每个库一行。
 * 分类直接用服务器返回的库名和顺序，不做统一映射。
 */
@Composable
fun SourceHomeScreen(
    repo: PhoneRepository,
    sourceId: String,
    onBack: () -> Unit,
    onPlay: (String, String?) -> Unit,
    onOpenCategory: (String, String) -> Unit,
    onOpenDetail: (String) -> Unit,
) {
    val p = DvTheme.palette
    // Hero 和桌面一样是一组（跨库挑带图的条目），底部圆点切换 + 定时轮播。
    // 状态按源缓存在页面外面：进详情再返回时不用重新拉一遍。
    val state = rememberSourceHomeState(sourceId)
    val heroes = state.heroes
    val heroIndex = state.heroIndex
    val libRows = state.libRows
    val watches = state.watches
    val loaded = state.loaded
    // 每个库前三张海报，用来拼 macOS 那种「三格海报 + 库名」的大卡。
    val libArts = state.libArts

    val config = repo.configs.firstOrNull { it.id == sourceId }
    val libs = repo.libraryOf(sourceId)
    val total = repo.totalOf(sourceId)

    LaunchedEffect(sourceId, libs) {
        if (!state.loaded) {
            loadSourceHome(repo = repo, state = state, sourceId = sourceId, libs = libs)
        } else {
            // 列表 / hero 用缓存，不再请求；继续观看是本地的播放记录，
            // 刚从播放页回来时进度可能变了，顺手刷一次。
            refreshWatches(repo, state, sourceId)
        }
        if (state.heroUpgraded) return@LaunchedEffect
        upgradeHeroes(repo = repo, state = state, libs = libs)
    }

    // 有多个时每 6 秒换一张（桌面版也是自动轮播）。
    LaunchedEffect(heroes.size) {
        if (heroes.size <= 1) return@LaunchedEffect
        while (true) {
            kotlinx.coroutines.delay(6_000)
            state.heroIndex = (state.heroIndex + 1) % heroes.size
        }
    }

    LazyColumn(
        state = state.list,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = TabReserve),
    ) {
        // 顶部大图：和详情页同一套「上半清晰、往下渐模糊」，标题压在图的下沿。
        item {
            val hero = heroes.getOrNull(heroIndex) ?: heroes.firstOrNull()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(392.dp)
                    // 整块都能点进详情：之前只有底部那几行字挂了 clickable，
                    // 点图片中间没反应。
                    .then(
                        if (hero != null) {
                            Modifier.clickableNoRipple { onOpenDetail(hero.id) }
                        } else {
                            Modifier
                        },
                    ),
            ) {
                HeroBackdrop(
                    path = hero?.backdrop ?: hero?.poster,
                    modifier = Modifier.fillMaxSize(),
                    // 图要露得更多：模糊和渐隐都往下压，别让整块 hero 都糊成毛玻璃。
                    bottomFadeStart = 0.50f,
                    blurStart = 0.44f,
                    blurEnd = 0.80f,
                )

                if (hero != null) {
                    // 照 macOS 首页 hero：标题 / meta / chips / 简介水平居中贴底，
                    // 下面是圆点（可点，也可以等它自己轮播）。
                    Column(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .clickableNoRipple { onOpenDetail(hero.id) }
                            .padding(
                                start = 24.dp,
                                end = 24.dp,
                                bottom = if (heroes.size > 1) 40.dp else 16.dp,
                            ),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            hero.title,
                            fontSize = DvType.PageTitle.fontSize,
                            lineHeight = 32.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = DvOnImage.Primary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            textAlign = TextAlign.Center,
                        )

                        if (hero.meta.isNotBlank()) {
                            Text(
                                hero.meta,
                                fontSize = DvType.CardTitle.fontSize,
                                color = DvOnImage.Secondary,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.padding(top = 7.dp),
                            )
                        }

                        if (hero.chips.isNotEmpty()) {
                            Row(
                                modifier = Modifier.padding(top = 9.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                hero.chips.take(3).forEach { text ->
                                    Text(
                                        text,
                                        fontSize = DvType.Caption.fontSize,
                                        color = DvOnImage.Primary,
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(6.dp))
                                            .background(Color.White.copy(alpha = 0.22f))
                                            .padding(horizontal = 9.dp, vertical = 3.dp),
                                    )
                                }
                            }
                        }

                        hero.overview?.takeIf { it.isNotBlank() }?.let { overview ->
                            Text(
                                overview,
                                fontSize = DvType.Caption.fontSize,
                                lineHeight = 18.sp,
                                color = DvOnImage.Secondary,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.padding(top = 9.dp),
                            )
                        }

                    }
                }

                if (heroes.size > 1) {
                    Row(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 13.dp),
                        horizontalArrangement = Arrangement.spacedBy(0.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        heroes.indices.forEach { index ->
                            Box(
                                modifier = Modifier
                                    .size(22.dp)
                                    .clickableNoRipple { state.heroIndex = index }
                                    // 视觉上还是 6dp 的点，可点区撑到 48dp。
                                    .minimumInteractiveComponentSize(),
                                contentAlignment = Alignment.Center,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(6.dp)
                                        .clip(RoundedCornerShape(percent = 50))
                                        .background(
                                            Color.White.copy(
                                                alpha = if (index == heroIndex) 0.92f else 0.35f,
                                            ),
                                        ),
                                )
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(start = 16.dp, top = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(Color.Black.copy(alpha = 0.40f))
                            .clickableNoRipple(onBack)
                            .minimumInteractiveComponentSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        DvGlyph(glyph = DvGlyph.Back, tint = DvOnImage.Icon, sizeDp = 15)
                    }
                    Text(
                        config?.name ?: sourceId,
                        fontSize = DvType.SectionTitle.fontSize,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 11.dp),
                    )
                }
            }
        }

        if (watches.isNotEmpty()) {
            item {
                SectionHeader(
                    "继续观看",
                    trailing = if (watches.size > 2) "全部 ${watches.size} 个" else null,
                    modifier = Modifier.padding(top = 14.dp, bottom = 8.dp),
                )
            }
            item {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = DvSpace.Gutter),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(watches, key = { it.itemId }) { record ->
                        WideCard(
                            record = record,
                            // 和桌面一致：点卡进详情（剧集用 parentId 回到整部剧），
                            // 想看就点详情里的播放。
                            onClick = { onOpenDetail(record.parentId ?: record.itemId) },
                        )
                    }
                }
            }
        }

        if (libs.isNotEmpty()) {
            item {
                SectionHeader(
                    "我的媒体",
                    modifier = Modifier.padding(top = 15.dp, bottom = 8.dp),
                )
            }
            item {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = DvSpace.Gutter),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    items(libs, key = { it.id }) { lib ->
                        LibraryCard(
                            title = lib.title,
                            arts = libArts[lib.id].orEmpty(),
                            onClick = { onOpenCategory(lib.id, lib.title) },
                        )
                    }
                }
            }
        }

        // 每个库一行（参考图里的「影视 2416 ›」）：不再放一条笼统的「最近添加」。
        libs.forEach { lib ->
            val row = libRows[lib.id].orEmpty()
            if (row.isEmpty()) return@forEach
            val count = repo.counts[lib.id]?.takeIf { it > 0 } ?: row.size.toLong()

            item(key = "lib-header-${lib.id}") {
                SectionHeader(
                    cleanTitle(lib.title),
                    trailing = "$count ›",
                    onTrailing = { onOpenCategory(lib.id, lib.title) },
                    modifier = Modifier.padding(top = 16.dp, bottom = 8.dp),
                )
            }
            item(key = "lib-row-${lib.id}") {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = DvSpace.Gutter),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(row, key = { it.id }) { item ->
                        PosterCard(item = item, onClick = { onOpenDetail(item.id) })
                    }
                }
            }
        }

        if (loaded && heroes.isEmpty()) {
            item {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text("这个源里还没有内容", style = DvType.Caption, color = p.faint)
                }
            }
        }

        item { Spacer(Modifier.height(8.dp)) }
    }
}

@Composable
private fun LibraryCard(
    title: String,
    arts: List<String>,
    onClick: () -> Unit,
) {
    val p = DvTheme.palette
    Box(
        modifier = Modifier
            .width(232.dp)
            .height(126.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickableNoRipple(onClick),
    ) {
        Row(modifier = Modifier.fillMaxSize()) {
            if (arts.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize().background(
                        Brush.linearGradient(
                            listOf(p.accent.copy(alpha = 0.20f), p.surfaceAlt),
                        ),
                    ),
                )
            } else {
                arts.forEach { art ->
                    RemoteImage(art, Modifier.weight(1f).fillMaxHeight())
                }
            }
        }

        // 底部压一道黑，白字才立得住（macOS 的 LibraryCard 同款）。
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.52f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.80f),
                ),
            ),
        )

        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .padding(start = 13.dp, end = 13.dp, bottom = 11.dp),
        ) {
            Text(
                cleanTitle(title),
                fontSize = DvType.Body.fontSize,
                fontWeight = FontWeight.SemiBold,
                color = DvOnImage.Primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * 首页 hero 的一张卡（对应桌面的 `HeroItem`）。
 *
 * 列表项常常没有横版图和动态范围，这里在详情回来之后补全，
 * 所以 meta / chips 在这里就拼好，UI 只负责显示。
 */
private data class HeroCard(
    val id: String,
    val title: String,
    val meta: String,
    val chips: List<String>,
    val overview: String?,
    val backdrop: String?,
    val poster: String?,
    val rating: Double,
)

private fun heroOf(item: MediaItem, d: MediaDetail? = null): HeroCard {
    val rating = (d?.rating ?: item.rating) ?: 0.0
    val year = (d?.releaseDate ?: item.releaseDate)?.take(4)?.takeIf { it.length == 4 }
    val kind = when ((d?.kind ?: item.kind).lowercase()) {
        "movie" -> "电影"
        "tv", "series", "episode" -> "剧集"
        "video" -> "视频"
        else -> ""
    }
    val episodes = d?.episodeCount ?: item.episodeCount
        ?: d?.localEpisodeCount ?: item.localEpisodeCount
    val meta = listOfNotNull(
        rating.takeIf { it > 0 }?.let { "%.1f 分".format(it) },
        year,
        kind.takeIf { it.isNotBlank() },
        episodes?.takeIf { it > 0 }?.let { "$it 集" },
    ).joinToString(" · ")

    val chips = listOfNotNull(
        (d?.resolution ?: item.resolution)?.takeIf { it.isNotBlank() },
        d?.colorRange?.takeIf { it.isNotBlank() },
        d?.audioType?.takeIf { it.isNotBlank() },
    )

    return HeroCard(
        id = item.id,
        title = cleanTitle(item.title),
        meta = meta,
        chips = chips,
        overview = d?.overview ?: item.overview,
        backdrop = d?.backdropPath ?: item.backdropPath,
        poster = d?.posterPath ?: item.posterPath,
        rating = rating,
    )
}

/**
 * 首屏数据：每个库第一页 + 继续观看，先把页面撑起来（hero 之后再补详情）。
 *
 * 放在 [SourceHomeScreen] 外面，是因为这些结果要按源缓存：从详情返回时
 * 页面会重建一次，不需要重新请求。
 */
private suspend fun loadSourceHome(
    repo: PhoneRepository,
    state: SourceHomeState,
    sourceId: String,
    libs: List<MediaLibrary>,
) {
    var allItems: List<MediaItem> = emptyList()

    if (libs.isNotEmpty()) {
        val rows = mutableMapOf<String, List<MediaItem>>()
        for (lib in libs.take(8)) {
            val page = runCatching {
                // 多取一页：hero 的候选从这里来，取太少圆点只有几个。
                repo.items(lib.id, page = 1, pageSize = 24, query = ListQuery(sort = "added", descending = true))
            }.getOrNull()
            rows[lib.id] = page?.items.orEmpty()
        }
        // 下面每库一行只展示前 12 个，其余留给 hero 当候选。
        state.libRows = rows.mapValues { (_, items) -> items.take(12) }
        state.libArts = rows.mapValues { (_, items) ->
            items.mapNotNull { it.posterPath }.filter { it.isNotBlank() }.take(3)
        }

        // 和桌面一样：候选打散，不再固定拿每个库「最新入库」的前几条。
        // 只要求有图；目录条目在后面拉详情时跳过。
        allItems = rows.values.flatten()
            .filter { !it.backdropPath.isNullOrBlank() || !it.posterPath.isNullOrBlank() }
            .distinctBy { it.id }
            .shuffled()

        state.heroes = allItems.take(8).map { heroOf(it) }
        state.heroIndex = 0
        android.util.Log.d(
            "DvHero",
            "候选 ${allItems.size} 条：${allItems.take(8).map { "${it.kind}/${it.backdropPath != null}" }}",
        )
    }

    refreshWatches(repo, state, sourceId)
    state.loaded = true

    state.candidates = allItems
}

/** 继续观看取本地播放记录，很便宜；每次进页面都刷，播放进度不会停在旧值。 */
private suspend fun refreshWatches(repo: PhoneRepository, state: SourceHomeState, sourceId: String) {
    state.watches = runCatching { repo.records() }
        .getOrDefault(emptyList())
        .filter { it.sourceId == sourceId }
        .take(8)
}

/** 照 macOS 的 `upgradeHeroes`：分批拉详情，补横版图 / 简介 / 评分。 */
private suspend fun upgradeHeroes(
    repo: PhoneRepository,
    state: SourceHomeState,
    libs: List<MediaLibrary>,
) {
    val allItems = state.candidates
    if (allItems.isEmpty()) {
        state.heroUpgraded = true
        return
    }

    // 照桌面的 upgradeHeroes：列表项常常只有竖版海报，分批取详情补横版图，
    // 有横版图 / 有简介 / 评分高的排前面；凑够几张就停，别把首屏拖太久。
    val fallback = state.heroes
    val upgraded = mutableListOf<HeroCard>()
    var publishedBackdrops = -1

    fun publish() {
        if (upgraded.isEmpty()) return
        // 横版图数量没变就不重设：每次重设都会让背景位图重算一遍，换得太勤会卡。
        val backdropNow = upgraded.count { !it.backdrop.isNullOrBlank() }
        if (backdropNow == publishedBackdrops) return
        publishedBackdrops = backdropNow
        val sorted = upgraded.sortedWith(
            compareByDescending<HeroCard> { !it.backdrop.isNullOrBlank() }
                .thenByDescending { !it.overview.isNullOrBlank() }
                .thenByDescending { it.rating },
        )
        val merged = (sorted + fallback).distinctBy { it.id }
        val withBackdrop = merged.filter { !it.backdrop.isNullOrBlank() }
        // 横版图够多就只用横版图；太少才拿竖版海报凑圆点。
        state.heroes = (if (withBackdrop.size >= 4) withBackdrop else merged).take(8)
        if (state.heroIndex !in state.heroes.indices) state.heroIndex = 0
    }

    suspend fun enrich(items: List<MediaItem>) {
        for (item in items) {
            val d = runCatching { repo.detail(item.id) }.getOrNull() ?: continue
            val card = heroOf(item, d)
            if (!card.backdrop.isNullOrBlank() || !card.poster.isNullOrBlank()) {
                upgraded += card
            }
        }
        publish()
    }

    fun backdropCount() = upgraded.count { !it.backdrop.isNullOrBlank() }

    // 第一轮：候选池里分批取详情。
    var processed = 0
    for (batch in allItems.take(24).chunked(3)) {
        processed += batch.size
        enrich(batch)
        if (processed >= 24) break
        if (backdropCount() >= 8) break
    }

    // 第二轮：第一页大多是目录（detail 拿不到横版图）时，照桌面按电影 / 剧集
    // 再查一批（打散），凑够 4 张横版图就停。
    if (backdropCount() < 4) {
        outer@ for (lib in libs.take(8)) {
            for (kind in listOf("movie", "tv")) {
                val page = runCatching {
                    repo.items(
                        lib.id,
                        page = 1,
                        pageSize = 24,
                        query = ListQuery(kinds = listOf(kind), sort = "added", descending = true),
                    )
                }.getOrNull() ?: continue
                if (page.items.isEmpty()) continue
                for (batch in page.items.shuffled().chunked(3)) {
                    enrich(batch)
                    if (backdropCount() >= 4) break@outer
                }
            }
        }
    }
    android.util.Log.i(
        "DvHero",
        "候选 ${allItems.size}，补到 ${backdropCount()} 张横版图，heroes=${state.heroes.size}",
    )
    publish()
    state.heroUpgraded = true
}

/**
 * 源首页的界面状态。
 *
 * 首页 → 详情会把首页从组合里移除，`remember` 的东西全丢；
 * 按 sourceId 把它寄存在这里，返回时直接复用（滚动位置一起保住）。
 */
private class SourceHomeState {
    var heroes by mutableStateOf<List<HeroCard>>(emptyList())
    var heroIndex by mutableIntStateOf(0)
    var libRows by mutableStateOf<Map<String, List<MediaItem>>>(emptyMap())
    var libArts by mutableStateOf<Map<String, List<String>>>(emptyMap())
    var watches by mutableStateOf<List<PlayRecord>>(emptyList())
    var candidates by mutableStateOf<List<MediaItem>>(emptyList())
    var loaded by mutableStateOf(false)
    var heroUpgraded by mutableStateOf(false)
    val list = LazyListState()
}

private val sourceHomeStates = mutableMapOf<String, SourceHomeState>()

@Composable
private fun rememberSourceHomeState(sourceId: String): SourceHomeState =
    remember(sourceId) { sourceHomeStates.getOrPut(sourceId) { SourceHomeState() } }
