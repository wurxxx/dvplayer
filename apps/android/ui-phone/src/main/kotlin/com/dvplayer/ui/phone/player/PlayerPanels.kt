package com.dvplayer.ui.phone.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.design.DvColors

enum class PlayerPanel { None, Audio, Subtitle, Episodes, Info }

private val card = Color(0xFF1F1F27)
private val divider = Color(0xFF3B3B49)
private val text = DvColors.Text
private val subtle = DvColors.Subtle
private val muted = DvColors.Muted
private val accent = DvColors.Accent

/** 底部弹出的选择面板：音轨 / 字幕 / 选集。 */
@Composable
fun PlayerBottomSheet(
    panel: PlayerPanel,
    model: PlayerUiModel,
    onDismiss: () -> Unit,
    onPickAudio: (Int) -> Unit,
    onPickSubtitle: (Int) -> Unit,
    onPickEpisode: (Int) -> Unit,
) {
    if (panel == PlayerPanel.None || panel == PlayerPanel.Info) return

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0x99000000))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 420.dp)
                .background(card, RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
                .navigationBarsPadding()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},
                ),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(46.dp)
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = when (panel) {
                        PlayerPanel.Audio -> "音轨"
                        PlayerPanel.Subtitle -> "字幕"
                        else -> "选集"
                    },
                    color = text,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    text = "关闭",
                    color = muted,
                    fontSize = 12.sp,
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onDismiss,
                    ),
                )
            }

            when (panel) {
                PlayerPanel.Audio -> TrackList(model.audios, onPickAudio)
                PlayerPanel.Subtitle -> TrackList(model.subtitles, onPickSubtitle)
                PlayerPanel.Episodes -> EpisodeList(model.episodes, onPickEpisode)
                else -> Unit
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun TrackList(tracks: List<PlayerTrack>, onPick: (Int) -> Unit) {
    // 用 Column 而不是 LazyColumn：后者会把剩余高度全部占掉，单条音轨也撑成满屏。
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
    ) {
        tracks.forEachIndexed { index, track ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = { onPick(index) },
                    )
                    .padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(track.title, color = text, fontSize = 13.sp)
                    Text(track.detail, color = muted, fontSize = 11.sp)
                }
                if (track.selected) {
                    DvIcon(DvIcon.Check, tint = accent, sizeDp = 16)
                }
            }
        }
    }
}

@Composable
private fun EpisodeList(episodes: List<PlayerEpisode>, onPick: (Int) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 340.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        episodes.forEachIndexed { index, episode ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = { onPick(index) },
                    )
                    .padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = episode.title,
                    color = if (episode.current) accent else text,
                    fontSize = 13.sp,
                    fontWeight = if (episode.current) FontWeight.SemiBold else FontWeight.Normal,
                    modifier = Modifier.weight(1f),
                )
                Text(episode.duration, color = muted, fontSize = 11.sp)
            }
        }
    }
}

/** 齿轮菜单：内核 / 媒体信息 / 比例 / 选集 / 定时关闭。 */
@Composable
fun PlayerSettingsMenu(
    model: PlayerUiModel,
    onDismiss: () -> Unit,
    onToggleEngine: () -> Unit,
    onInfo: () -> Unit,
    onEpisodes: () -> Unit,
    onRatio: () -> Unit,
    onSleep: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(184.dp)
            .background(Color(0xF2202028), RoundedCornerShape(10.dp))
            .padding(vertical = 4.dp),
    ) {
        MenuRow(
            label = "播放内核",
            value = model.chips.firstOrNull { it.accent }?.text ?: "mpv",
            onClick = onToggleEngine,
        )
        HorizontalDivider()
        MenuRow("媒体信息", null, onInfo)
        MenuRow("画面比例", "适应", onRatio)
        MenuRow("选集", if (model.episodes.isEmpty()) null else "${model.episodes.size} 集", onEpisodes)
        MenuRow("定时关闭", "关", onSleep)
    }
}

@Composable
private fun MenuRow(label: String, value: String?, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = text, fontSize = 12.sp)
        Spacer(Modifier.weight(1f))
        if (value != null) {
            Text(value, color = muted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun HorizontalDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .height(1.dp)
            .background(Color(0x1FFFFFFF)),
    )
}

/** 媒体信息：整页覆盖，视频 / 音轨 / 字幕 / 源。 */
@Composable
fun PlayerInfoPanel(
    model: PlayerUiModel,
    onDismiss: () -> Unit,
    onPickAudio: (Int) -> Unit,
    onPickSubtitle: (Int) -> Unit,
    /** 横屏沉浸时系统栏已经隐藏，不需要留状态栏高度。 */
    statusBarInset: Boolean = true,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            // 必须完全不透明：半透明会把底下的选集 / 进度条透出来。
            .background(Color(0xFF141419)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (statusBarInset) Modifier.statusBarsPadding() else Modifier)
                .height(40.dp)
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "媒体信息",
                color = text,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            IconAction(DvIcon.Close, 18, onDismiss, contentDescription = "关闭")
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(2.dp))
            Section("视频") {
                KeyValue("编码", model.video.codec)
                KeyValue("分辨率", model.video.resolution)
                KeyValue("动态范围", model.video.colorRange)
                KeyValue("帧率", model.video.frameRate)
                KeyValue("码率", model.video.bitRate)
                KeyValue("位深", model.video.bitDepth)
                KeyValue("内核", model.video.engine)
            }

            Section("音轨") {
                if (model.audios.isEmpty()) {
                    EmptyRow("源未提供音轨信息")
                } else {
                    model.audios.forEachIndexed { index, track ->
                        PickRow(track, onClick = { onPickAudio(index) })
                    }
                }
            }

            Section("字幕") {
                model.subtitles.forEachIndexed { index, track ->
                    PickRow(track, onClick = { onPickSubtitle(index) })
                }
            }

            Section("源") {
                KeyValue("名称", "${model.source.name}（${model.source.kind}）")
                KeyValue("直连", if (model.source.direct) "是" else "否（走服务器转码）")
                KeyValue(
                    "请求头",
                    if (model.source.headers == 0) "无" else "${model.source.headers} 条",
                )
                model.source.resumeAtMs?.let { KeyValue("续播点", formatTime(it)) }
            }

            model.video.warning?.let { warning ->
                Text(
                    text = warning,
                    color = accent,
                    fontSize = 11.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 4.dp, bottom = 12.dp)
                        .background(Color(0x14FFB020), RoundedCornerShape(6.dp))
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                )
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) {
        Text(title, color = muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(6.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(card, RoundedCornerShape(10.dp))
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            content()
        }
    }
}

@Composable
private fun KeyValue(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Text(
            text = label,
            color = muted,
            fontSize = 11.sp,
            modifier = Modifier.width(76.dp),
        )
        Text(
            text = value,
            color = text,
            fontSize = 11.sp,
            fontFamily = FontFamily.Default,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun EmptyRow(text: String) {
    Text(
        text = text,
        color = muted,
        fontSize = 11.sp,
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
    )
}

@Composable
private fun PickRow(track: PlayerTrack, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(track.title, color = text, fontSize = 12.sp)
            Text(track.detail, color = muted, fontSize = 10.sp)
        }
        if (track.selected) {
            DvIcon(DvIcon.Check, tint = accent, sizeDp = 15)
        }
    }
}

/** 加载 / 错误覆盖层（静态版先给结构，接内核后由状态驱动）。 */
@Composable
fun PlayerLoadingOverlay(text: String) {
    Box(
        modifier = Modifier.fillMaxSize().background(Color(0xE6000000)),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = subtle, fontSize = 13.sp)
    }
}
