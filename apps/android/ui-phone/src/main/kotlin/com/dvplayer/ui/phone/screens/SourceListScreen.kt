package com.dvplayer.ui.phone.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.MediaLibrary
import com.dvplayer.core.SourceConfig
import com.dvplayer.core.SourceConnection
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvPageInset
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.ui.phone.data.PhoneRepository

/**
 * 媒体库首页 = 源列表。
 *
 * 源卡片而不是源内容：一个 App 挂三四个源时，先让用户选「去哪」，比把所有源的
 * 内容混在一条流里清楚。统计数字按服务器原样显示（Emby 的库名叫什么就显示什么）。
 */
@Composable
fun SourceListScreen(
    repo: PhoneRepository,
    onOpenSource: (String) -> Unit,
    onReconnect: (String) -> Unit,
    onAddSource: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    val trouble = repo.connections.count { !it.value.ok } + (repo.configs.size - repo.connections.size).coerceAtLeast(0)

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = TabReserve),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        item {
            Column(modifier = Modifier.padding(start = DvPageInset, end = DvPageInset, top = 10.dp, bottom = 3.dp)) {
                Text("媒体库", style = DvType.PageTitle, color = p.text)
                Text(
                    text = buildString {
                        append("${repo.configs.size} 个源")
                        if (repo.connecting) append(" · 正在连接")
                        else if (trouble > 0) append(" · $trouble 个需要处理")
                        else if (repo.configs.isNotEmpty()) append(" · 全部已连接")
                    },
                    style = DvType.Micro,
                    color = if (trouble > 0 && !repo.connecting) p.warning else p.faint,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }

        if (repo.configs.isEmpty() && repo.ready) {
            item {
                EmptySourceHint(onAddSource)
            }
        }

        items(repo.configs, key = { it.id }) { config ->
            val conn = repo.connections[config.id]
            SourceCard(
                config = config,
                conn = conn,
                connecting = (repo.connecting && conn == null) || config.id in repo.reconnecting,
                libraries = repo.libraryOf(config.id),
                counts = repo.counts,
                // 连上的进源首页，失败的当重试按钮——卡片上写的「点一下重试」得真的能点。
                onClick = {
                    if (conn?.ok == true) onOpenSource(config.id) else onReconnect(config.id)
                },
                modifier = Modifier.padding(horizontal = DvPageInset),
            )
        }

        item {
            if (repo.configs.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .padding(horizontal = DvPageInset)
                        .padding(top = 2.dp)
                        .fillMaxWidth()
                        .height(40.dp)
                        .clip(RoundedCornerShape(13.dp))
                        .border(1.dp, if (p.isDark) Color.White.copy(alpha = 0.13f) else Color.Black.copy(alpha = 0.10f), RoundedCornerShape(13.dp))
                        .clickableNoRipple(onAddSource),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    DvGlyph(DvGlyph.Plus, tint = p.faint, sizeDp = 12)
                    Spacer(Modifier.width(5.dp))
                    Text("添加媒体源", style = DvType.Caption, color = p.faint)
                }
            }
        }
    }
}

@Composable
private fun EmptySourceHint(onAddSource: () -> Unit) {
    val p = DvTheme.palette
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = DvSpace.Gutter, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(15.dp))
                .background(p.accentSoft),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(DvGlyph.Folder, tint = p.accent, sizeDp = 22)
        }
        Text("还没有媒体源", style = DvType.SectionTitle, color = p.text)
        Text(
            "添加 Emby、Jellyfin、FnOS 或本地目录，\n源里的电影和剧集会按库列出来。",
            style = DvType.Caption,
            color = p.faint,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Spacer(Modifier.height(3.dp))
        Row {
            com.dvplayer.ui.phone.ui.PrimaryButton("添加媒体源", onAddSource, glyph = DvGlyph.Plus)
        }
    }
}

@Composable
private fun SourceCard(
    config: SourceConfig,
    conn: SourceConnection?,
    connecting: Boolean,
    libraries: List<MediaLibrary>,
    counts: Map<String, Long>,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    val ok = conn?.ok == true
    val failed = conn != null && !conn.ok
    val accent = brandColor(config.kind, p.accent)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            // 参考图里的源卡带一层很淡的源色：Emby 偏蓝、飞牛偏绿，左上到右下渐隐。
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        accent.copy(alpha = if (p.isDark) 0.16f else 0.11f),
                        p.surface,
                    ),
                ),
            )
            .border(
                1.dp,
                if (p.isDark) Color.White.copy(alpha = 0.08f) else Color.Black.copy(alpha = 0.045f),
                RoundedCornerShape(20.dp),
            )
            .then(if (ok || failed) Modifier.clickableNoRipple(onClick) else Modifier)
            .padding(start = 14.dp, end = 14.dp, top = 13.dp, bottom = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = config.kind.take(1).uppercase(),
                    color = accent,
                    fontSize = DvType.Body.fontSize,
                    fontWeight = FontWeight.ExtraBold,
                )
            }
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    config.name,
                    style = DvType.CardTitle,
                    fontWeight = FontWeight.SemiBold,
                    color = p.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "${config.kind.uppercase()} · ${shortAddress(config.kind, config.base)}",
                    style = DvType.Micro,
                    color = p.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(6.dp))
            StatusBadge(ok = ok, connecting = connecting, failed = failed)
        }

        if (failed) {
            Text(
                text = "点一下重试 · " + friendlyError(conn?.error),
                style = DvType.Micro,
                color = p.danger,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .padding(top = 8.dp)
                    .fillMaxWidth(),
            )
        } else {
            Box(
                Modifier
                    .padding(top = 9.dp)
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(p.divider),
            )
            Row(
                modifier = Modifier
                    .padding(top = 8.dp)
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                libraries.forEach { lib ->
                    val n = counts[lib.id]
                    Column {
                        Text(
                            text = n?.toString() ?: "—",
                            style = DvType.Numeral,
                            color = if (n == null) p.faint else p.text,
                        )
                        Text(
                            lib.title,
                            style = DvType.Micro,
                            color = p.faint,
                            maxLines = 1,
                        )
                    }
                }
                if (libraries.isEmpty()) {
                    Text("等待连接…", style = DvType.Micro, color = p.faint)
                }
            }
        }
    }
}

@Composable
private fun StatusBadge(ok: Boolean, connecting: Boolean, failed: Boolean) {
    val p = DvTheme.palette
    val (color, text) = when {
        connecting -> p.faint to "连接中"
        ok -> p.success to "已连接"
        failed -> p.danger to "失败"
        else -> p.faint to "未连接"
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(5.dp)
                .clip(RoundedCornerShape(99.dp))
                .background(color),
        )
        Spacer(Modifier.width(4.dp))
        Text(text, style = DvType.Micro, color = color, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * 把适配器抛上来的英文 HTTP 错误收成一句人话。
 *
 * 原始错误里有 URL 和状态码，对排查有用，但一行放不下也不会有人读；
 * 设置页里点「重连」失败时会再往 logcat 打一次原文。
 */
private fun friendlyError(raw: String?): String {
    val text = raw?.trim().orEmpty()
    if (text.isEmpty()) return "连接失败"
    return when {
        text.contains("401") || text.contains("403") -> "用户名或密码不对"
        text.contains("网络需要网页认证") -> "网络需要网页认证，先用浏览器登录一次"
        // 准入系统对没登录过的设备不是重定向就是直接 RST，两种都给同一句自救提示。
        text.contains("reset by peer", true) ||
            text.contains("Connection reset", true) -> "连接被网络拦截，先在浏览器登录网络"
        text.contains("timed out", true) ||
            text.contains("timeout", true) ||
            text.contains("error sending request", true) -> "连不上服务器，检查地址和网络"
        text.contains("connection refused", true) -> "服务器拒绝了连接"
        text.contains("No such host", true) || text.contains("dns", true) -> "域名解析失败"
        else -> text
    }
}

/**
 * 卡片第二行只放能区分源的部分。
 *
 * 本地源的 base 是一长串应用私有路径，整段显示既挤又没有信息量；远程源留主机名，
 * 路径留给设置页。
 */
private fun shortAddress(kind: String, base: String): String {
    if (kind.equals("local", ignoreCase = true)) return "本地目录"
    val trimmed = base.trim()
    // 别用 removePrefix：用户填的 scheme 可能是大写 HTTP://。
    val host = trimmed.substringAfter("://", trimmed).trimEnd('/')
    return host.substringBefore('/').ifBlank { trimmed }
}

private fun brandColor(kind: String, fallback: Color): Color = when (kind.lowercase()) {
    "emby" -> Color(0xFF52B54B)
    "jellyfin" -> Color(0xFFAA5CC3)
    "fnos" -> Color(0xFF6366F1)
    "local" -> Color(0xFF00A4DC)
    "smb", "webdav" -> Color(0xFF00A4DC)
    else -> fallback
}
