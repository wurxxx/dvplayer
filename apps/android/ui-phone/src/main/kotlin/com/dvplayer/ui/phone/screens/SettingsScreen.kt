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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.ui.phone.data.PhoneRepository

@Composable
fun SettingsScreen(
    repo: PhoneRepository,
    onAddSource: () -> Unit,
    onReconnect: (String) -> Unit,
) {
    val p = DvTheme.palette
    val context = LocalContext.current
    val version = remember {
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "0.1.0"
    }
    var hdrSwitch by remember { mutableStateOf(true) }
    var autoNext by remember { mutableStateOf(false) }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = DvSpace.Gutter,
            end = DvSpace.Gutter,
            bottom = TabReserve,
        ),
    ) {
        item {
            Text(
                "设置",
                style = DvType.PageTitle,
                color = p.text,
                modifier = Modifier.padding(top = 10.dp, bottom = 4.dp),
            )
        }

        // 媒体源
        item { GroupLabel("媒体源") }
        item {
            CardBox {
                repo.configs.forEachIndexed { index, cfg ->
                    val conn = repo.connections[cfg.id]
                    SourceRow(
                        name = cfg.name,
                        detail = "${cfg.kind.uppercase()} · ${cfg.base}",
                        ok = conn?.ok == true,
                        failed = conn != null && !conn.ok,
                        connecting = repo.connecting && conn == null,
                        onClick = { onReconnect(cfg.id) },
                        onRemove = { repo.removeSource(cfg.id) },
                        showDivider = index != repo.configs.lastIndex,
                    )
                }
                if (repo.configs.isEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickableNoRipple(onAddSource)
                            .padding(horizontal = 10.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("还没有源，点这里添加", style = DvType.Caption, color = p.faint)
                    }
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickableNoRipple(onAddSource)
                        .padding(horizontal = 10.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconBox(DvGlyph.Plus)
                    Spacer(Modifier.width(9.dp))
                    Text("添加媒体源", style = DvType.Caption, color = p.accent)
                }
            }
        }

        // 播放
        item { GroupLabel("播放") }
        item {
            CardBox {
                SettingRow(DvGlyph.Media, "默认内核", "自动", showDivider = true)
                SettingRow(DvGlyph.CheckCircle, "HDR10+ 切 Media3", null, showDivider = true) {
                    DvToggle(hdrSwitch) { hdrSwitch = it }
                }
                SettingRow(DvGlyph.Play, "播完自动下一集", null, showDivider = false) {
                    DvToggle(autoNext) { autoNext = it }
                }
            }
        }

        // 外观
        item { GroupLabel("外观") }
        item {
            CardBox {
                SettingRow(DvGlyph.Settings, "主题", "跟随系统", showDivider = false)
            }
        }

        // 关于
        item { GroupLabel("关于") }
        item {
            CardBox {
                SettingRow(DvGlyph.Star, "版本", version, showDivider = false)
            }
        }

        item { Spacer(Modifier.height(12.dp)) }
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(
        text,
        style = DvType.Micro,
        fontSize = DvType.Micro.fontSize,
        color = DvTheme.palette.faint,
        letterSpacing = 0.6.sp,
        modifier = Modifier.padding(top = 16.dp, bottom = 6.dp, start = 2.dp),
    )
}

@Composable
private fun CardBox(content: @Composable () -> Unit) {
    val p = DvTheme.palette
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(13.dp))
            .background(p.surface)
            .border(1.dp, if (p.isDark) Color.White.copy(alpha = 0.06f) else Color.Black.copy(alpha = 0.035f), RoundedCornerShape(13.dp)),
    ) {
        content()
    }
}

@Composable
private fun SettingRow(
    glyph: DvGlyph,
    label: String,
    value: String?,
    showDivider: Boolean,
    trailing: (@Composable () -> Unit)? = null,
) {
    val p = DvTheme.palette
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconBox(glyph)
        Spacer(Modifier.width(9.dp))
        Text(
            label,
            style = DvType.Caption,
            fontSize = DvType.CardTitle.fontSize,
            color = p.text,
            modifier = Modifier.weight(1f),
        )
        if (value != null) {
            Text(value, style = DvType.Caption, color = p.faint)
        }
        trailing?.invoke()
    }
    if (showDivider) {
        Box(
            Modifier
                .padding(start = 41.dp)
                .fillMaxWidth()
                .height(1.dp)
                .background(p.divider),
        )
    }
}

@Composable
private fun IconBox(glyph: DvGlyph) {
    val p = DvTheme.palette
    Box(
        modifier = Modifier
            .size(22.dp)
            .clip(RoundedCornerShape(6.5.dp))
            .background(p.accentSoft),
        contentAlignment = Alignment.Center,
    ) {
        DvGlyph(glyph, tint = p.accent, sizeDp = 12)
    }
}

@Composable
private fun SourceRow(
    name: String,
    detail: String,
    ok: Boolean,
    failed: Boolean,
    connecting: Boolean,
    onClick: () -> Unit,
    onRemove: () -> Unit,
    showDivider: Boolean,
) {
    val p = DvTheme.palette
    val color = when {
        connecting -> p.faint
        ok -> p.success
        failed -> p.danger
        else -> p.faint
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickableNoRipple(onClick)
            .padding(horizontal = 10.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(6.5.dp))
                .background(color.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(DvGlyph.Media, tint = color, sizeDp = 12)
        }
        Spacer(Modifier.width(9.dp))
        Column(Modifier.weight(1f)) {
            Text(
                name,
                style = DvType.Caption,
                fontSize = DvType.CardTitle.fontSize,
                color = p.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                detail,
                style = DvType.Micro,
                color = p.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = if (failed) "删除" else "重连",
            style = DvType.Micro,
            color = if (failed) p.danger else p.muted,
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .clickableNoRipple(if (failed) onRemove else onClick)
                .padding(horizontal = 6.dp, vertical = 3.dp),
        )
    }
    if (showDivider) {
        Box(
            Modifier
                .padding(start = 41.dp)
                .fillMaxWidth()
                .height(1.dp)
                .background(p.divider),
        )
    }
}

@Composable
fun DvToggle(on: Boolean, onChange: (Boolean) -> Unit) {
    val p = DvTheme.palette
    Box(
        modifier = Modifier
            .width(21.dp)
            .height(13.dp)
            .clip(RoundedCornerShape(99.dp))
            .background(if (on) p.accent else if (p.isDark) Color.White.copy(alpha = 0.16f) else Color.Black.copy(alpha = 0.13f))
            .clickableNoRipple { onChange(!on) },
    ) {
        Box(
            Modifier
                .align(if (on) Alignment.CenterEnd else Alignment.CenterStart)
                .padding(1.5.dp)
                .size(10.dp)
                .clip(RoundedCornerShape(99.dp))
                .background(Color.White),
        )
    }
}
