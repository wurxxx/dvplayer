package com.dvplayer.ui.phone.screens

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.MediaDetail
import com.dvplayer.core.MediaInfo
import androidx.compose.ui.unit.Dp
import com.dvplayer.ui.phone.ui.RemoteImage
import com.dvplayer.ui.phone.ui.IconAction
import com.dvplayer.core.Person
import com.dvplayer.core.MediaItem
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.aspectRatio
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvOnImage
import com.dvplayer.design.DvPalettes
import com.dvplayer.design.DvTheme
import com.dvplayer.design.LocalDvPalette
import com.dvplayer.design.DvType
import com.dvplayer.design.LocalDvWindow
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.data.TrackPrefs
import com.dvplayer.ui.phone.ui.HeroBackdrop
import com.dvplayer.ui.phone.ui.runtimeLabel
import com.dvplayer.ui.phone.ui.cleanTitle
import kotlinx.coroutines.launch

/**
 * 详情页，照 macOS 的 `DetailPage` 移植：
 *
 * - 背景是一张图，上半清晰、往下渐模糊（`HeroBackdrop`），文字和按钮直接浮在图上；
 * - 标题、年份、chips、简介、操作按钮贴着图的下沿排；
 * - 操作是一排胶囊按钮（主按钮强调色，其余半透明），手机放不下就横向滑；
 * - 图下方是页面底色，放媒体信息和链接。
 */
@Composable
fun DetailScreen(
    repo: PhoneRepository,
    itemId: String,
    onBack: () -> Unit,
    onPlay: (String, String?) -> Unit,
) {
    // 详情页整页压在大图（它的模糊版）上。深色主题照旧用深色调色板；
    // 浅色主题下背景压白雾、正文和卡片都走浅色，否则「浅色模式」打开还是
    // 一整页黑底白字。图上的文字色由 DvPalette.onImage* 一组扩展决定。
    val palette = if (isSystemInDarkTheme()) DvPalettes.Dark else DvPalettes.Light
    CompositionLocalProvider(LocalDvPalette provides palette) {
        DetailBody(repo = repo, itemId = itemId, onBack = onBack, onPlay = onPlay)
    }
}

@Composable
private fun DetailBody(
    repo: PhoneRepository,
    itemId: String,
    onBack: () -> Unit,
    onPlay: (String, String?) -> Unit,
) {
    val p = DvTheme.palette
    val window = LocalDvWindow.current
    // 平板是「左海报 + 右信息」，海报尺寸同时决定背景从哪里开始糊。
    val twoColumn = window.medium
    val posterWidth = if (window.expanded) 250.dp else 200.dp
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var detail by remember(itemId) { mutableStateOf<MediaDetail?>(null) }
    var favorite by remember(itemId) { mutableStateOf(false) }
    var watched by remember(itemId) { mutableStateOf(false) }
    var error by remember(itemId) { mutableStateOf<String?>(null) }
    var episodes by remember(itemId) { mutableStateOf<List<MediaItem>>(emptyList()) }
    var people by remember(itemId) { mutableStateOf<List<Person>>(emptyList()) }
    var mediaInfo by remember(itemId) { mutableStateOf<MediaInfo?>(null) }
    // 详情页选的音轨 / 字幕：存进 TrackPrefs，播放页起播时自动应用。
    var audioChoice by remember { mutableIntStateOf(TrackPrefs.audioIndex(context)) }
    var subtitleChoice by remember { mutableIntStateOf(TrackPrefs.subtitleIndex(context)) }
    var pickingAudio by remember { mutableStateOf(false) }
    var pickingSubtitle by remember { mutableStateOf(false) }
    // 选集：快捷分段（1-30 / 31-60 …）要能把这一行滚过去。
    val episodeListState = rememberLazyListState()
    var selectedRangeStart by remember(itemId) { mutableIntStateOf(0) }
    // 上次看到的位置（秒）和那一集的集号，照桌面的「播放 第 20 集 01:53」。
    var resumeSeconds by remember(itemId) { mutableIntStateOf(0) }
    var resumeEpisode by remember(itemId) { mutableStateOf<Int?>(null) }
    // 续播那一集的 id：集卡就靠它描边高亮（macOS 的 EpisodeCard.active）。
    var resumeEpisodeId by remember(itemId) { mutableStateOf<String?>(null) }
    var didAutoJumpEpisode by remember(itemId) { mutableStateOf(false) }

    LaunchedEffect(itemId) {
        runCatching { repo.detail(itemId) }
            .onSuccess { d ->
                detail = d
                favorite = d.isFavorite == true
                watched = d.isWatched == true

                // 选集：剧集先拿季，再拿这一季的集；单季（singleChildId）少走一步。
                runCatching {
                    val first = d.singleChildId ?: d.id
                    val kids = repo.children(first, pageSize = 200).items
                    if (kids.any { it.kind == "season" }) {
                        val season = kids.first()
                        repo.children(season.id, pageSize = 500).items
                    } else {
                        kids
                    }
                }.onSuccess {
                    // 按集号升序：接口多半按「最近添加」倒序给，直接摆出来是 E13、E12…
                    episodes = it
                        .filter { ep -> ep.kind == "episode" || ep.isPlayable }
                        .sortedBy { ep -> ep.episodeNumber ?: Int.MAX_VALUE }
                }

                // 演职人员：源不支持时返回空表，不弹错。
                people = repo.people(d.id)

                // 媒体信息走源的真实轨道接口（视频/音频/字幕），不再用详情里那几个摘要字段拼。
                mediaInfo = repo.mediaInfo(d.playItemId ?: d.id)

                // 续播点：剧集看有进度的那一集，电影看自己的播放记录。
                val records = runCatching { repo.records() }.getOrDefault(emptyList())
                val resumeEp = episodes.firstOrNull { it.progress > 0.01 && it.progress < 0.995 }
                val record = resumeEp?.let { ep -> records.firstOrNull { it.itemId == ep.id } }
                    ?: records.firstOrNull { it.itemId == itemId }
                    ?: records.firstOrNull { it.itemId == d.playItemId }
                resumeSeconds = record?.positionSeconds?.toInt() ?: 0
                resumeEpisode = resumeEp?.episodeNumber
                resumeEpisodeId = resumeEp?.id
            }
            .onFailure { error = it.message }
    }

    // 一进详情就定位到看到一半的那一集：选集行滚过去（照 macOS 的
    // autoJumpToResumeIfNeeded）。只在第一次生效，用户自己点分段后不再拉回。
    LaunchedEffect(itemId, episodes, resumeEpisodeId) {
        if (didAutoJumpEpisode || resumeEpisodeId == null) return@LaunchedEffect
        val index = episodes.indexOfFirst { it.id == resumeEpisodeId }
        if (index < 0) return@LaunchedEffect
        didAutoJumpEpisode = true
        // 用 scrollToItem 而不是 animate：打开页面时不应该看到选集行自己滑一下。
        episodeListState.scrollToItem(index)
    }

    // 背景图实际占的高度（由 HeroBackdrop 量出来）：手机的文字从图下沿往下排，
    // 首帧还没量到时先按 240dp 兜底。
    var backdropImageHeight by remember(itemId) { mutableStateOf(0.dp) }
    val textTopPadding = if (twoColumn) {
        0.dp
    } else if (backdropImageHeight > 0.dp) {
        backdropImageHeight + 30.dp
    } else {
        240.dp
    }

    val d = detail
    val playTarget = d?.playItemId ?: d?.singleChildId ?: itemId

    Box(modifier = Modifier.fillMaxSize().background(p.background)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            // 背景分两种：
            // - 手机：图按宽度完整显示在顶部，图的下沿一段渐变收到页面底色
            //   （浅色白 / 深色黑），正文排在底色上。不做模糊、不做延伸。
            // - 平板：双栏，海报和文字都压在图上，图要铺满第一屏并在下部
            //   继续模糊，否则白字会落到浅底上看不清。
            Box(modifier = Modifier.fillMaxWidth().heightIn(min = LocalDvWindow.current.height)) {
                if (twoColumn) {
                    val heroBlock = 88.dp + posterWidth * 1.5f + 26.dp
                    HeroBackdrop(
                        path = d?.backdropPath ?: d?.posterPath,
                        modifier = Modifier.matchParentSize(),
                        fitWhole = true,
                        blurStart = 0.32f,
                        blurEnd = 0.58f,
                        blurStartDp = heroBlock + 20.dp,
                        blurEndDp = heroBlock + 280.dp,
                        fadeStartDp = 310.dp,
                        fadeEndDp = 500.dp,
                    )
                } else {
                    HeroBackdrop(
                        path = d?.backdropPath ?: d?.posterPath,
                        modifier = Modifier.matchParentSize(),
                        imageOnly = true,
                        // 手机的文字从图下沿往下排；图高由背景量出来回调上来。
                        onImageHeight = { backdropImageHeight = it },
                    )
                }
                Column(modifier = Modifier.fillMaxWidth()) {
                    // 平板：左海报 + 右信息并排，标题不再孤零零地漂在大图上；
                    // 手机（compact）保持原样：图 240dp，文字照旧往下排。
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(
                                start = if (twoColumn) 32.dp else 0.dp,
                                top = if (twoColumn) 88.dp else 0.dp,
                            ),
                        horizontalArrangement = Arrangement.spacedBy(if (twoColumn) 28.dp else 0.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        if (twoColumn) {
                            RemoteImage(
                                path = d?.posterPath ?: d?.backdropPath,
                                modifier = Modifier
                                    .width(posterWidth)
                                    .aspectRatio(2f / 3f)
                                    .clip(RoundedCornerShape(14.dp)),
                            )
                        }
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .padding(
                                    start = if (twoColumn) 0.dp else 20.dp,
                                    end = if (twoColumn) 32.dp else 20.dp,
                                    top = textTopPadding,
                                    bottom = 0.dp,
                                ),
                        ) {
                            // 标题位置在所有详情页都一致，不会因为简介长短忽上忽下。
                            if (d == null) {
                                Text(
                                    error ?: "加载中…",
                                    style = DvType.Caption,
                                    color = photoSubText(),
                                    modifier = Modifier.padding(vertical = 24.dp),
                                )
                            } else {
                                Column {
                                    Text(
                                        cleanTitle(d.title),
                                        fontSize = DvType.Display.fontSize,
                                        lineHeight = 36.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = photoText(),
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )

                                    val meta = listOfNotNull(
                                        d.releaseDate?.take(4),
                                        runtimeLabel(d.runtimeSeconds),
                                        d.status?.takeIf { it.isNotBlank() },
                                        d.rating?.takeIf { it > 0 }?.let { "%.1f 分".format(it) },
                                    ).joinToString(" · ")
                                    if (meta.isNotBlank()) {
                                        Text(
                                            meta,
                                            fontSize = DvType.CardTitle.fontSize,
                                            color = photoSubText(),
                                            modifier = Modifier.padding(top = 8.dp),
                                        )
                                    }

                                    val chips = chipsOf(d)
                                    if (chips.isNotEmpty()) {
                                        Row(
                                            modifier = Modifier.padding(top = 9.dp),
                                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        ) {
                                            chips.take(5).forEach { Chip(it) }
                                        }
                                    }

                                    val overview = d.overview
                                    if (!overview.isNullOrBlank()) {
                                        Text(
                                            overview,
                                            fontSize = DvType.CardTitle.fontSize,
                                            lineHeight = 19.sp,
                                            color = photoSubText(),
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.padding(top = 11.dp),
                                        )
                                    }

                                    // 播放：白色整条胶囊，位置不变；看过的带「第 N 集 01:53」。
                                    val playLabel = buildString {
                                        append("播放")
                                        resumeEpisode?.let { append(" 第 $it 集") }
                                        if (resumeSeconds >= 5) {
                                            append(" ${formatDuration(resumeSeconds)}")
                                        }
                                    }
                                    PlayPill(
                                        text = playLabel,
                                        onClick = { onPlay(playTarget, itemId) },
                                        modifier = Modifier
                                            .align(Alignment.CenterHorizontally)
                                            .padding(top = 16.dp),
                                    )

                                    // 其余操作合并成一行：每个都是圆形底 + 图标 + 小字，不再垫整条底色。
                                    // 只在有得选时才摆按钮：单音轨 / 单字幕 / 没配 Trakt 都不显示。
                                    val audios = mediaInfo?.audios.orEmpty()
                                    val subtitles = mediaInfo?.subtitles.orEmpty()
                                    val showAudio = audios.size > 1
                                    val showSubtitle = subtitles.size > 1
                                    val audioActive = audioChoice in audios.indices
                                    val subtitleActive = subtitleChoice in subtitles.indices

                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                                        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                                        verticalAlignment = Alignment.Top,
                                    ) {
                                        RoundAction(
                                            glyph = if (favorite) DvGlyph.HeartFilled else DvGlyph.Heart,
                                            label = if (favorite) "已收藏" else "收藏",
                                            active = favorite,
                                            onClick = {
                                                val next = !favorite
                                                favorite = next
                                                scope.launch {
                                                    runCatching { repo.setFavorite(itemId, next) }.onFailure { err ->
                                                        favorite = !next
                                                        Toast.makeText(context, err.message ?: "收藏失败", Toast.LENGTH_SHORT).show()
                                                    }
                                                }
                                            },
                                            modifier = Modifier,
                                        )
                                        RoundAction(
                                            glyph = DvGlyph.CheckCircle,
                                            label = if (watched) "已观看" else "标记已看",
                                            active = watched,
                                            onClick = {
                                                val next = !watched
                                                watched = next
                                                scope.launch {
                                                    runCatching { repo.setWatched(itemId, next) }.onFailure { err ->
                                                        watched = !next
                                                        Toast.makeText(context, err.message ?: "操作失败", Toast.LENGTH_SHORT).show()
                                                    }
                                                }
                                            },
                                            modifier = Modifier,
                                        )
                                        if (showAudio) {
                                            RoundAction(
                                                glyph = DvGlyph.Audio,
                                                label = "音轨",
                                                active = audioActive,
                                                onClick = { pickingAudio = true },
                                                modifier = Modifier,
                                            )
                                        }
                                        if (showSubtitle) {
                                            RoundAction(
                                                glyph = DvGlyph.Subtitle,
                                                label = if (subtitleChoice == TrackPrefs.SUBTITLE_OFF) "字幕关" else "字幕",
                                                active = subtitleActive,
                                                onClick = { pickingSubtitle = true },
                                                modifier = Modifier,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // 这里必须用 Spacer 而不是 Box 的 padding：双栏时 Row 的高度由
                    // 海报（300dp）决定，文字列上的 bottom padding 会被吃掉。
                    Spacer(Modifier.height(32.dp))

                    // 图下方：媒体信息和链接。它们也压在图的下半部，滚过图之后才落在底色上。
                    // 大屏收在 1040dp 里居中：否则三条轨道卡摊在 1280dp 上，中间全是洞。
                    Column(
                        modifier = Modifier
                            .widthIn(max = if (window.expanded) 1040.dp else Dp.Unspecified)
                            .fillMaxWidth()
                            .align(Alignment.CenterHorizontally)
                            .padding(horizontal = if (window.medium) 32.dp else 20.dp),
                    ) {
                        if (d != null) {
                            if (episodes.isNotEmpty()) {
                                SectionTitle("选集", trailing = "${episodes.size} 集")

                                // 集数多时给一排「1-30 / 31-60 …」：点一下滚到那一段
                                // （照 macOS 的 episodeRangeChips）。段大小 30。
                                val ranges = episodeRanges(episodes.size)
                                if (ranges.isNotEmpty()) {
                                    val activeStart = if (selectedRangeStart > 0) {
                                        selectedRangeStart
                                    } else {
                                        val n = resumeEpisode ?: 1
                                        ((n - 1) / EpisodeRangeSize) * EpisodeRangeSize + 1
                                    }
                                    Row(
                                        modifier = Modifier
                                            .padding(top = 10.dp)
                                            .horizontalScroll(rememberScrollState()),
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    ) {
                                        ranges.forEach { (from, to) ->
                                            RangeChip(
                                                label = "$from-$to",
                                                active = activeStart == from,
                                                onClick = {
                                                    selectedRangeStart = from
                                                    val target = episodes.indexOfFirst {
                                                        (it.episodeNumber ?: 0) >= from
                                                    }
                                                    if (target >= 0) {
                                                        scope.launch {
                                                            episodeListState.animateScrollToItem(target)
                                                        }
                                                    }
                                                },
                                            )
                                        }
                                    }
                                }

                                LazyRow(
                                    state = episodeListState,
                                    modifier = Modifier.padding(top = 10.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    items(episodes, key = { it.id }) { ep ->
                                        EpisodeCard(
                                            ep = ep,
                                            active = ep.id == resumeEpisodeId,
                                            onClick = { onPlay(ep.id, itemId) },
                                        )
                                    }
                                }
                            }

                            if (people.isNotEmpty()) {
                                SectionTitle(
                                    "演职人员",
                                    trailing = "${people.size} 位",
                                    modifier = Modifier.padding(top = 32.dp),
                                )
                                LazyRow(
                                    modifier = Modifier.padding(top = 10.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    // 同一个演员可能同时在「演员 / 导演」里各来一条，
                                    // 只用 id 当 key 会撞（真机上就是这么崩的），带上序号。
                                    itemsIndexed(
                                        people,
                                        key = { index, person -> "$index-${person.id}" },
                                    ) { _, person ->
                                        CastCard(person)
                                    }
                                }
                            }

                            val tracks = trackCards(mediaInfo)
                            if (tracks.isNotEmpty()) {
                                SectionTitle(
                                    "媒体信息",
                                    trailing = "${tracks.size} 条轨道",
                                    // 上面是选集卡片下的「第 N 集」小字，24 + 那 8dp
                                    // 正好和其余小节的 32dp 对齐。
                                    modifier = Modifier.padding(top = 24.dp),
                                )
                                // 高度交给内容：同一行用最高那张卡拉齐，行数不写死。
                                Row(
                                    modifier = Modifier
                                        .padding(top = 10.dp)
                                        .fillMaxWidth()
                                        .horizontalScroll(rememberScrollState())
                                        .height(IntrinsicSize.Max),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    tracks.forEach { card ->
                                        InfoCard(
                                            card.title,
                                            card.rows,
                                            glyph = card.glyph,
                                            fillHeight = true,
                                        )
                                    }
                                }
                            } else {
                                // 源没给轨道（本地目录 / 老版本服务器）：退回详情里的摘要字段。
                                val info = infoCards(d)
                                if (info.isNotEmpty()) {
                                    SectionTitle("媒体信息", modifier = Modifier.padding(top = 24.dp))
                                    Row(
                                        modifier = Modifier
                                            .padding(top = 10.dp)
                                            .fillMaxWidth()
                                            .horizontalScroll(rememberScrollState())
                                            .height(IntrinsicSize.Max),
                                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    ) {
                                        info.forEach { (title, rows) ->
                                            InfoCard(title, rows, fillHeight = true)
                                        }
                                    }
                                }
                            }

                            // 视频存放位置：电影 / 单集给文件路径，剧集给所在目录（和桌面一致）。
                            val location = locationText(mediaInfo, d.kind)
                            if (location != null) {
                                SectionTitle("存储位置", modifier = Modifier.padding(top = 32.dp))
                                Row(
                                    modifier = Modifier.padding(top = 10.dp).fillMaxWidth(),
                                    verticalAlignment = Alignment.Top,
                                ) {
                                    DvGlyph(glyph = DvGlyph.Folder, tint = p.faint, sizeDp = 13)
                                    Text(
                                        location,
                                        fontSize = DvType.Micro.fontSize,
                                        lineHeight = 17.sp,
                                        color = p.muted,
                                        fontFamily = FontFamily.Monospace,
                                        modifier = Modifier.padding(start = 8.dp),
                                    )
                                }
                            }

                            val links = linkButtons(d)
                            if (links.isNotEmpty()) {
                                SectionTitle("链接", modifier = Modifier.padding(top = 32.dp))
                                Row(
                                    modifier = Modifier.padding(top = 10.dp),
                                    horizontalArrangement = Arrangement.spacedBy(9.dp),
                                ) {
                                    links.forEach { (label, url) ->
                                        LinkPill(label) {
                                            runCatching {
                                                context.startActivity(
                                                    Intent(Intent.ACTION_VIEW, Uri.parse(url)),
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Spacer(Modifier.height(TabReserve))
                    }
                }
            }
        }

        if (pickingAudio) {
            TrackPickerDialog(
                title = "选择音轨",
                options = mediaInfo?.audios.orEmpty().mapIndexed { index, audio ->
                    index to (audio.title ?: languageLabel(audio.language) ?: "音轨 ${index + 1}")
                },
                selected = audioChoice,
                onPick = {
                    audioChoice = it
                    TrackPrefs.setAudioIndex(context, it)
                    pickingAudio = false
                },
                onDismiss = { pickingAudio = false },
            )
        }

        if (pickingSubtitle) {
            TrackPickerDialog(
                title = "选择字幕",
                options = buildList {
                    add(TrackPrefs.SUBTITLE_OFF to "关闭字幕")
                    mediaInfo?.subtitles.orEmpty().forEachIndexed { index, sub ->
                        add(index to (sub.title ?: languageLabel(sub.language) ?: "字幕 ${index + 1}"))
                    }
                },
                selected = if (subtitleChoice < 0) TrackPrefs.SUBTITLE_OFF else subtitleChoice,
                onPick = {
                    subtitleChoice = it
                    TrackPrefs.setSubtitleIndex(context, it)
                    pickingSubtitle = false
                },
                onDismiss = { pickingSubtitle = false },
            )
        }

        // 返回：黑底半透明圆，压在图上。
        Box(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(start = 16.dp, top = 10.dp)
                .size(36.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.40f))
                .clickableNoRipple(onBack),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(glyph = DvGlyph.Back, tint = DvOnImage.Icon, sizeDp = 15)
        }
    }
}

/** 白色胶囊播放键：模糊背景上最亮的那一层。 */
@Composable
private fun PlayPill(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 压在剧照上时用白胶囊（macOS 的样子）；手机上浅色主题正文在浅底上，
    // 白胶囊会糊掉，改强调色。
    val light = onLightPage()
    val bg = if (light) DvTheme.palette.accent else Color.White
    val fg = if (light) DvTheme.palette.onAccent else Color.Black
    // 宽度写死：续播文案长短（第几集 / 时间）不再让按钮忽大忽小。
    Row(
        modifier = modifier
            .width(208.dp)
            .height(50.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(bg)
            .clickableNoRipple(onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DvGlyph(glyph = DvGlyph.Play, tint = fg, sizeDp = 17)
        Text(
            text,
            color = fg,
            fontSize = DvType.SectionTitle.fontSize,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 7.dp),
        )
    }
}

/** 圆形底 + 图标 + 小字：操作行里每个按钮各自带一个圆，不共用一条底色。 */
@Composable
private fun RoundAction(
    glyph: DvGlyph,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    active: Boolean = false,
) {
    val p = DvTheme.palette
    Column(
        modifier = modifier.width(62.dp).clickableNoRipple(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(
                    when {
                        active -> p.accent.copy(alpha = 0.26f)
                        onLightPage() -> p.glassPill
                        else -> p.surface.copy(alpha = if (p.isDark) 0.44f else 0.52f)
                    },
                )
                .border(
                    1.dp,
                    if (onLightPage()) Color.Black.copy(alpha = 0.08f)
                    else Color.White.copy(alpha = 0.16f),
                    RoundedCornerShape(percent = 50),
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(
                glyph = glyph,
                // 这几个按钮压在照片上，不能用调色板里的灰（浅色主题下几乎看不见），
                // 统一走白色 alpha，和 GlassAction 一致。
                tint = if (active) p.accent else if (onLightPage()) p.text else DvOnImage.Icon,
                sizeDp = 18,
                strokeWidth = if (active) 0.085f else 0.07f,
            )
        }
        Text(
            label,
            color = if (active) p.accent else photoSubText(),
            fontSize = DvType.Micro.fontSize,
            maxLines = 1,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/** 圆形玻璃按钮 + 小字，参考图里收藏 / 已观看的样子。 */
@Composable
private fun GlassAction(
    glyph: DvGlyph,
    label: String,
    active: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    Column(
        modifier = modifier.width(62.dp).clickableNoRipple(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(RoundedCornerShape(percent = 50))
                .background(
                    if (active) p.accent.copy(alpha = 0.26f)
                    else Color.White.copy(alpha = if (p.isDark) 0.14f else 0.44f),
                )
                .border(
                    1.dp,
                    Color.White.copy(alpha = 0.22f),
                    RoundedCornerShape(percent = 50),
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(
                glyph = glyph,
                tint = if (active) p.accent else DvOnImage.Icon,
                sizeDp = 21,
                strokeWidth = if (active) 0.085f else 0.07f,
            )
        }
        Text(
            label,
            color = if (active) p.accent else DvOnImage.Secondary,
            fontSize = DvType.Micro.fontSize,
            modifier = Modifier.padding(top = 7.dp),
        )
    }
}

/** 选集卡：16:9 缩略图 + 第 N 集 + 标题 + 进度。 */
@Composable
private fun EpisodeCard(ep: MediaItem, active: Boolean = false, onClick: () -> Unit) {
    val p = DvTheme.palette
    val number = ep.episodeNumber?.takeIf { it > 0 }
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = Modifier
            .width(176.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickableNoRipple(onClick),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(shape)
                // 看到一半的那一集描个边，进详情一眼能找到（和 macOS 一致）。
                .border(2.dp, if (active) p.accent else Color.Transparent, shape),
        ) {
            RemoteImage(ep.backdropPath ?: ep.posterPath, Modifier.fillMaxSize())
            if (number != null) {
                Text(
                    "E%02d".format(number),
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(6.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
            if (ep.progress > 0.01) {
                Box(
                    Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .height(3.dp)
                        .background(Color.Black.copy(alpha = 0.4f)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(ep.progress.toFloat().coerceIn(0f, 1f))
                            .fillMaxHeight()
                            // 高亮卡上进度条改成白色，和强调色描边分开。
                            .background(if (active) Color.White.copy(alpha = 0.95f) else p.accent),
                    )
                }
            }
        }
        Text(
            if (number != null) "第 $number 集" else cleanTitle(ep.title),
            fontSize = DvType.Caption.fontSize,
            color = if (active) p.accent else p.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

/** 演员卡：竖版头像 + 名字 + 角色。 */
@Composable
private fun CastCard(person: Person) {
    val p = DvTheme.palette
    Column(modifier = Modifier.width(88.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(9.dp)),
        ) {
            if (person.imagePath != null) {
                RemoteImage(person.imagePath, Modifier.fillMaxSize())
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(p.surface),
                    contentAlignment = Alignment.Center,
                ) {
                    DvGlyph(glyph = DvGlyph.Star, tint = p.faint, sizeDp = 22)
                }
            }
        }
        Text(
            person.name,
            fontSize = DvType.Caption.fontSize,
            color = p.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
        val role = person.role ?: person.job
        if (!role.isNullOrBlank()) {
            Text(
                role,
                fontSize = DvType.Micro.fontSize,
                color = p.muted.copy(alpha = 0.85f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
    }
}

/** 主按钮强调色底，其余半透明玻璃胶囊 —— 和 macOS 的 Primary/SecondaryButtonStyle 一致。 */
@Composable
private fun ActionPill(
    glyph: DvGlyph,
    label: String,
    primary: Boolean = false,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    val p = DvTheme.palette
    val background = when {
        primary -> p.accent
        active -> p.accent.copy(alpha = 0.26f)
        else -> p.surface.copy(alpha = 0.55f)
    }
    val content = when {
        primary -> p.onAccent
        active -> p.accent
        else -> DvOnImage.Primary
    }
    Row(
        modifier = Modifier
            .height(38.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(background)
            .border(
                width = 1.dp,
                color = when {
                    primary -> Color.Transparent
                    p.isDark -> Color.White.copy(alpha = 0.10f)
                    else -> Color.Black.copy(alpha = 0.08f)
                },
                shape = RoundedCornerShape(10.dp),
            )
            .clickableNoRipple(onClick)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DvGlyph(glyph = glyph, tint = content, sizeDp = 14)
        Text(
            label,
            color = content,
            fontSize = DvType.CardTitle.fontSize,
            fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Normal,
            modifier = Modifier.padding(start = 7.dp),
        )
    }
}

/** 图上的一行小标签：white 0.18 底。 */
@Composable
private fun Chip(text: String) {
    Text(
        text = text,
        fontSize = DvType.Caption.fontSize,
        color = photoText(),
        modifier = Modifier
            .clip(RoundedCornerShape(5.dp))
            // 浅色主题的正文在浅底上：胶囊要立得住，否则和底色糊在一起。
            .background(
                if (onLightPage()) DvTheme.palette.glassPill
                else Color.White.copy(alpha = 0.22f),
            )
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/**
 * 正文颜色：平板双栏时文字压在图上（恒白）；手机上文字落在图的下面、
 * 页面底色上——浅色主题用正文色，深色主题仍然是白字。
 */
@Composable
private fun photoText(): Color =
    if (LocalDvWindow.current.medium) DvOnImage.Primary else DvTheme.palette.text

@Composable
private fun photoSubText(): Color =
    if (LocalDvWindow.current.medium) DvOnImage.Secondary else DvTheme.palette.muted

/** 手机上浅色主题：文字在浅色底上，胶囊/圆底要换成白玻璃。 */
@Composable
private fun onLightPage(): Boolean =
    !LocalDvWindow.current.medium && !DvTheme.palette.isDark

@Composable
private fun SectionTitle(
    text: String,
    trailing: String? = null,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text,
            fontSize = DvType.SectionTitle.fontSize,
            fontWeight = FontWeight.SemiBold,
            color = p.text,
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) {
            Text(trailing, fontSize = DvType.Caption.fontSize, color = p.faint)
        }
    }
}

@Composable
private fun InfoCard(
    title: String,
    rows: List<Pair<String, String>>,
    glyph: DvGlyph? = null,
    fillHeight: Boolean = false,
) {
    InfoCardBody(title, rows, glyph, fillHeight)
}

@Composable
private fun InfoCardBody(
    title: String,
    rows: List<Pair<String, String>>,
    glyph: DvGlyph?,
    fillHeight: Boolean,
) {
    val p = DvTheme.palette
    Column(
        modifier = Modifier
            .width(220.dp)
            .then(if (fillHeight) Modifier.fillMaxHeight() else Modifier)
            .clip(RoundedCornerShape(14.dp))
            // 照 macOS 的 MediaInfoCard：详情页整页是模糊大图，卡片用半透明，
            // 让底下的画面透一点出来；实心 surfaceAlt 会变成一块死黑的板子，
            // 和暖色调的背景也接不上。深色下 0.80 是「能看出底下有画面、但不再透字」
            // 的厚度；浅色主题下卡是白的，给到 0.92 才是真的白玻璃。
            .background(
                if (p.isDark) p.surface.copy(alpha = 0.80f)
                else Color.White.copy(alpha = 0.92f),
            )
            .border(
                1.dp,
                if (p.isDark) Color.White.copy(alpha = 0.07f) else Color.Black.copy(alpha = 0.06f),
                RoundedCornerShape(14.dp),
            )
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (glyph != null) {
                DvGlyph(glyph = glyph, tint = p.faint, sizeDp = 13)
                Spacer(Modifier.width(6.dp))
            }
            Text(
                title,
                fontSize = DvType.CardTitle.fontSize,
                color = p.subtle,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        rows.forEach { (key, value) ->
            Row(modifier = Modifier.padding(top = 5.dp)) {
                Text(key, fontSize = DvType.Micro.fontSize, color = p.faint, modifier = Modifier.width(58.dp))
                Text(
                    value,
                    fontSize = DvType.Micro.fontSize,
                    color = p.subtle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun LinkPill(label: String, onClick: () -> Unit) {
    LinkPillBody(label, onClick)
}

@Composable
private fun LinkPillBody(label: String, onClick: () -> Unit) {
    val p = DvTheme.palette
    Row(
        modifier = Modifier
            .height(36.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(
                if (p.isDark) p.surface.copy(alpha = 0.80f)
                else Color.White.copy(alpha = 0.92f),
            )
            .border(
                1.dp,
                if (p.isDark) Color.White.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.06f),
                RoundedCornerShape(percent = 50),
            )
            .clickableNoRipple(onClick)
            .padding(horizontal = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DvGlyph(glyph = DvGlyph.Link, tint = p.muted, sizeDp = 13)
        Text(label, fontSize = DvType.CardTitle.fontSize, color = p.text, modifier = Modifier.padding(start = 7.dp))
    }
}

private data class TrackCard(
    val title: String,
    val glyph: DvGlyph,
    val rows: List<Pair<String, String>>,
)

/**
 * 把源返回的 [MediaInfo] 拆成横滑卡片：每条视频 / 音频 / 字幕轨道一张。
 *
 * 这是接口里的真实数据（编码、分辨率、帧率、比特率、语言…），
 * 不再用详情里那几个「分辨率 / 动态范围 / 声道」摘要字段。
 */
private fun trackCards(info: MediaInfo?): List<TrackCard> {
    if (info == null) return emptyList()
    val cards = mutableListOf<TrackCard>()

    info.video?.let { v ->
        val rows = listOfNotNull(
            v.codec?.takeIf { it.isNotBlank() }?.let { "编码" to it },
            when {
                (v.width ?: 0) > 0 && (v.height ?: 0) > 0 -> "分辨率" to "${v.width} x ${v.height}"
                else -> null
            },
            v.frameRate?.takeIf { it > 0 }?.let { "帧率" to "%.2f fps".format(it) },
            bitRateText(v.bitRate)?.let { "比特率" to it },
            v.colorRange?.takeIf { it.isNotBlank() }?.let { "动态范围" to it },
            v.bitDepth?.takeIf { it > 0 }?.let { "位深" to "$it bit" },
            v.profile?.takeIf { it.isNotBlank() }?.let { "配置" to it },
            v.pixelFormat?.takeIf { it.isNotBlank() }?.let { "像素格式" to it },
        )
        cards += TrackCard(v.title ?: "视频", DvGlyph.Play, rows)
    }

    info.audios.forEachIndexed { index, a ->
        val rows = listOfNotNull(
            a.language?.takeIf { it.isNotBlank() }?.let { "语言" to it },
            a.codec?.takeIf { it.isNotBlank() }?.let { "编码" to it },
            a.channels?.takeIf { it > 0 }?.let { "声道" to "$it ch" },
            a.sampleRate?.takeIf { it > 0 }?.let { "采样率" to "$it Hz" },
            bitRateText(a.bitRate)?.let { "比特率" to it },
            a.profile?.takeIf { it.isNotBlank() }?.let { "配置" to it },
            a.layout?.takeIf { it.isNotBlank() }?.let { "布局" to it },
            if (a.isDefault) "默认" to "是" else null,
        )
        cards += TrackCard(a.title ?: "音频 ${index + 1}", DvGlyph.Audio, rows)
    }

    info.subtitles.forEachIndexed { index, sub ->
        val rows = listOfNotNull(
            sub.language?.takeIf { it.isNotBlank() }?.let { "语言" to it },
            sub.title?.takeIf { it.isNotBlank() }?.let { "标题" to it },
            sub.codec?.takeIf { it.isNotBlank() }?.let { "编码" to it },
            sub.format?.takeIf { it.isNotBlank() }?.let { "格式" to it },
            if (sub.isBitmap) "图形字幕" to "是" else null,
            if (sub.isExternal) "外部" to "是" else null,
            if (sub.isDefault) "默认" to "是" else null,
        )
        cards += TrackCard(sub.title ?: "字幕 ${index + 1}", DvGlyph.Subtitle, rows)
    }

    return cards
}

/** 视频存放位置：电影 / 单集给文件路径，剧集 / 季给所在目录。 */
private fun locationText(info: MediaInfo?, kind: String?): String? {
    val raw = info?.path?.trim().orEmpty()
    if (raw.isEmpty()) return null
    return when (kind.orEmpty().lowercase()) {
        "movie", "video", "episode" -> raw
        else -> raw.substringBeforeLast('/', raw).ifBlank { raw }
    }
}

/** 音轨 / 字幕选择弹窗：一行一个，当前选中的打勾。 */
@Composable
private fun TrackPickerDialog(
    title: String,
    options: List<Pair<Int, String>>,
    selected: Int,
    onPick: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val p = DvTheme.palette
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, fontWeight = FontWeight.SemiBold, color = p.text) },
        text = {
            Column {
                options.forEach { (index, label) ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickableNoRipple { onPick(index) }
                            .padding(horizontal = 8.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            label,
                            fontSize = DvType.Body.fontSize,
                            color = if (index == selected) p.accent else p.text,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (index == selected) {
                            DvGlyph(glyph = DvGlyph.CheckCircle, tint = p.accent, sizeDp = 16)
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = p.muted)
            }
        },
        containerColor = p.surface,
    )
}

/** `zh` / `chi` 这类语言码转中文名，认不出就原样返回。 */
private fun languageLabel(code: String?): String? {
    val raw = code?.trim().orEmpty()
    if (raw.isEmpty()) return null
    return when (raw.lowercase()) {
        "zh", "chi", "zho", "zh-cn", "zh-hans" -> "中文"
        "zh-tw", "zh-hant" -> "繁体中文"
        "en", "eng" -> "英语"
        "ja", "jpn" -> "日语"
        "ko", "kor" -> "韩语"
        "fr", "fra", "fre" -> "法语"
        "de", "deu", "ger" -> "德语"
        "es", "spa" -> "西班牙语"
        "ru", "rus" -> "俄语"
        else -> raw
    }
}

/** 秒 → `H:MM:SS` / `M:SS`，和桌面的 MediaText.duration 一样。 */
private fun formatDuration(seconds: Int): String {
    if (seconds <= 0) return "00:00"
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

private fun bitRateText(value: Long?): String? {
    val v = value ?: return null
    if (v <= 0) return null
    return when {
        v >= 1_000_000_000 -> "%.2f Gbps".format(v / 1_000_000_000.0)
        v >= 1_000_000 -> "%.1f Mbps".format(v / 1_000_000.0)
        v >= 1_000 -> "%.0f kbps".format(v / 1_000.0)
        else -> "$v bps"
    }
}

private fun chipsOf(d: MediaDetail): List<String> {
    val kind = when (d.kind.lowercase()) {
        "movie" -> "电影"
        "series", "tv" -> "剧集"
        "season" -> "季"
        "episode" -> "剧集"
        else -> "视频"
    }
    return listOfNotNull(
        kind,
        d.resolution?.takeIf { it.isNotBlank() },
        d.audioType?.takeIf { it.isNotBlank() },
        d.colorRange?.takeIf { it.isNotBlank() },
        (d.localEpisodeCount ?: d.episodeCount)?.takeIf { it > 0 }?.let { "$it 集" },
    )
}

private fun infoCards(d: MediaDetail): List<Pair<String, List<Pair<String, String>>>> {
    val cards = mutableListOf<Pair<String, List<Pair<String, String>>>>()

    val video = listOfNotNull(
        d.resolution?.takeIf { it.isNotBlank() }?.let { "分辨率" to it },
        d.colorRange?.takeIf { it.isNotBlank() }?.let { "动态范围" to it },
    )
    if (video.isNotEmpty()) cards += "视频" to video

    val audio = listOfNotNull(
        d.audioType?.takeIf { it.isNotBlank() }?.let { "声道" to it },
    )
    if (audio.isNotEmpty()) cards += "音频" to audio

    val counts = listOfNotNull(
        d.seasonCount?.takeIf { it > 0 }?.let { "季" to "$it" },
        (d.localEpisodeCount ?: d.episodeCount)?.takeIf { it > 0 }?.let { "集" to "$it" },
        runtimeLabel(d.runtimeSeconds)?.let { "时长" to it },
    )
    if (counts.isNotEmpty()) cards += "剧集" to counts

    return cards
}

private fun linkButtons(d: MediaDetail): List<Pair<String, String>> {
    val links = mutableListOf<Pair<String, String>>()
    val title = d.title.substringBefore(" - ").substringBefore("（").trim()
    if (title.isNotEmpty()) {
        links += "豆瓣" to "https://search.douban.com/movie/subject_search?search_text=${Uri.encode(title)}"
    }
    d.tmdbId?.takeIf { it.isNotBlank() }?.let {
        val kind = if (d.kind.lowercase() in setOf("movie")) "movie" else "tv"
        links += "TMDB" to "https://www.themoviedb.org/$kind/$it"
    }
    d.imdbId?.takeIf { it.isNotBlank() }?.let {
        links += "IMDb" to "https://www.imdb.com/title/$it/"
    }
    return links
}

/** 快捷选集一段多少集（和 macOS 的 `episodeRangeSize` 一致）。 */
private const val EpisodeRangeSize = 30

/** 集数超过一段时才分段：1-30 / 31-60 / 61-70。 */
private fun episodeRanges(total: Int): List<Pair<Int, Int>> {
    if (total <= EpisodeRangeSize) return emptyList()
    return (1..total step EpisodeRangeSize).map { from ->
        from to minOf(from + EpisodeRangeSize - 1, total)
    }
}

/** 选集分段按钮：压在图上的半透明胶囊，选中段用更亮的底。 */
@Composable
private fun RangeChip(label: String, active: Boolean, onClick: () -> Unit) {
    val p = DvTheme.palette
    val shape = RoundedCornerShape(percent = 50)
    Text(
        text = label,
        fontSize = DvType.Caption.fontSize,
        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
        // 选集总落在图的下沿之后（页面底色上），跟着正文色走：
        // 深色主题白字，浅色主题深色字。
        color = if (active) p.text else p.muted,
        modifier = Modifier
            .clip(shape)
            .background(
                when {
                    !LocalDvWindow.current.medium -> {
                        // 手机：压在图外时是白胶囊，压在图上时仍是白色半透。
                        if (onLightPage()) Color.White.copy(alpha = if (active) 0.92f else 0.55f)
                        else Color.White.copy(alpha = if (active) 0.26f else 0.12f)
                    }
                    else -> Color.White.copy(alpha = if (active) 0.26f else 0.12f)
                },
            )
            .border(
                1.dp,
                if (onLightPage()) {
                    Color.Black.copy(alpha = if (active) 0.10f else 0.06f)
                } else {
                    Color.White.copy(alpha = if (active) 0.32f else 0.14f)
                },
                shape,
            )
            .clickableNoRipple(onClick)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}
