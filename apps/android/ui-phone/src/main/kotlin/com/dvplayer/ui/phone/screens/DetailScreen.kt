package com.dvplayer.ui.phone.screens

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.aspectRatio
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvPalettes
import com.dvplayer.design.DvTheme
import com.dvplayer.design.LocalDvPalette
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.design.DvOnImage
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
    // 详情页整页压在大图（它的模糊版）上：标题、meta、chips 本来就是白色硬编码，
    // 再用浅色调色板会出现「白字落在浅灰底上」。这里统一换成深色调色板，
    // 背景、正文、信息卡片全走深色，和播放页一致。
    CompositionLocalProvider(LocalDvPalette provides DvPalettes.Dark) {
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
    // 上次看到的位置（秒）和那一集的集号，照桌面的「播放 第 20 集 01:53」。
    var resumeSeconds by remember(itemId) { mutableIntStateOf(0) }
    var resumeEpisode by remember(itemId) { mutableStateOf<Int?>(null) }

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
            }
            .onFailure { error = it.message }
    }

    val d = detail
    val playTarget = d?.playItemId ?: d?.singleChildId ?: itemId

    Box(modifier = Modifier.fillMaxSize().background(p.background)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
        ) {
            // 背景铺满**整个内容高度**（不是一屏）：滚到哪都还是这张图的模糊版，
            // 不会滚出一片页面底色。清晰图只在上部，下面全是同源氛围色。
            Box(modifier = Modifier.fillMaxWidth()) {
                HeroBackdrop(
                    path = d?.backdropPath ?: d?.posterPath,
                    modifier = Modifier.matchParentSize(),
                    // 手机竖屏比横图窄得多：按宽度完整显示，别把两边裁掉。
                    fitWhole = true,
                    // 模糊往后挪：图的上 3/4 都保持清晰（标题压在图下沿也不糊）。
                    blurStart = 0.75f,
                    // 最底下再收到页面底色，滚到底不会硬切。
                    bottomFadeStart = 0.90f,
                )
                Column(modifier = Modifier.fillMaxWidth()) {
                    // 顶部固定留一段图（240dp），文字从这里往下排：
                    // 标题位置在所有详情页都一致，不会因为简介长短忽上忽下。
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 20.dp, end = 20.dp, top = 240.dp, bottom = 26.dp),
                    ) {
                        if (d == null) {
                            Text(
                                error ?: "加载中…",
                                style = DvType.Caption,
                                color = DvOnImage.Secondary,
                                modifier = Modifier.padding(vertical = 24.dp),
                            )
                        } else {
                            Column {
                                Text(
                                    cleanTitle(d.title),
                                    fontSize = DvType.Display.fontSize,
                                    lineHeight = 36.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = DvOnImage.Primary,
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
                                        color = DvOnImage.Secondary,
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
                                        color = DvOnImage.Secondary,
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

                    // 图下方：媒体信息和链接。它们也压在图的下半部，滚过图之后才落在底色上。
                    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
                        if (d != null) {
                            if (episodes.isNotEmpty()) {
                                SectionTitle("选集", trailing = "${episodes.size} 集")
                                LazyRow(
                                    modifier = Modifier.padding(top = 10.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    items(episodes, key = { it.id }) { ep ->
                                        EpisodeCard(ep) { onPlay(ep.id, itemId) }
                                    }
                                }
                            }

                            if (people.isNotEmpty()) {
                                SectionTitle(
                                    "演职人员",
                                    trailing = "${people.size} 位",
                                    modifier = Modifier.padding(top = 24.dp),
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
                                SectionTitle("媒体信息", trailing = "${tracks.size} 条轨道")
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
                                    SectionTitle("媒体信息")
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
                                SectionTitle("存储位置", modifier = Modifier.padding(top = 24.dp))
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
                                SectionTitle("链接", modifier = Modifier.padding(top = 24.dp))
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
    // 宽度写死：续播文案长短（第几集 / 时间）不再让按钮忽大忽小。
    Row(
        modifier = modifier
            .width(208.dp)
            .height(50.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(Color.White)
            .clickableNoRipple(onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DvGlyph(glyph = DvGlyph.Play, tint = Color.Black, sizeDp = 17)
        Text(
            text,
            color = Color.Black,
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
                    if (active) p.accent.copy(alpha = 0.26f)
                    else p.surface.copy(alpha = if (p.isDark) 0.44f else 0.52f),
                )
                .border(
                    1.dp,
                    Color.White.copy(alpha = 0.16f),
                    RoundedCornerShape(percent = 50),
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(
                glyph = glyph,
                // 这几个按钮压在照片上，不能用调色板里的灰（浅色主题下几乎看不见），
                // 统一走白色 alpha，和 GlassAction 一致。
                tint = if (active) p.accent else DvOnImage.Icon,
                sizeDp = 18,
                strokeWidth = if (active) 0.085f else 0.07f,
            )
        }
        Text(
            label,
            color = if (active) p.accent else DvOnImage.Secondary,
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
private fun EpisodeCard(ep: MediaItem, onClick: () -> Unit) {
    val p = DvTheme.palette
    val number = ep.episodeNumber?.takeIf { it > 0 }
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
                .clip(RoundedCornerShape(10.dp)),
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
                            .background(p.accent),
                    )
                }
            }
        }
        Text(
            if (number != null) "第 $number 集" else cleanTitle(ep.title),
            fontSize = DvType.Caption.fontSize,
            color = p.text,
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
                color = if (primary) Color.Transparent else Color.White.copy(alpha = 0.10f),
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
        color = DvOnImage.Primary,
        modifier = Modifier
            .clip(RoundedCornerShape(5.dp))
            .background(Color.White.copy(alpha = 0.22f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

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
    val p = DvTheme.palette
    Column(
        modifier = Modifier
            .width(220.dp)
            .then(if (fillHeight) Modifier.fillMaxHeight() else Modifier)
            .clip(RoundedCornerShape(14.dp))
            // 照 macOS 的 MediaInfoCard：详情页整页是模糊大图，卡片用半透明，
            // 让底下的画面透一点出来；实心 surfaceAlt 会变成一块死黑的板子，
            // 和暖色调的背景也接不上。靠亮度差分开，不套描边。
            .background(p.surface.copy(alpha = 0.55f))
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
    val p = DvTheme.palette
    Row(
        modifier = Modifier
            .height(36.dp)
            .clip(RoundedCornerShape(percent = 50))
            .background(p.surface.copy(alpha = if (p.isDark) 0.62f else 0.72f))
            .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(percent = 50))
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
