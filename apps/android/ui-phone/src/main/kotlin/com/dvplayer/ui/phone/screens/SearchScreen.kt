package com.dvplayer.ui.phone.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.MediaItem
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.ui.DvPill
import com.dvplayer.ui.phone.ui.PosterCard
import kotlinx.coroutines.delay

private val HotKeywords = listOf("沙丘", "诺兰", "4K 原盘", "杜比视界", "科幻", "剧集")

@Composable
fun SearchScreen(
    repo: PhoneRepository,
    onOpenDetail: (String) -> Unit,
) {
    val p = DvTheme.palette
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var searched by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    // 300ms 防抖：每敲一个字都打一次全源搜索，Emby 上会很慢。
    LaunchedEffect(query) {
        val q = query.trim()
        if (q.isEmpty()) {
            results = emptyList()
            searched = false
            error = null
            return@LaunchedEffect
        }
        delay(300)
        searching = true
        runCatching { repo.search(q) }
            .onSuccess {
                results = it.items
                error = if (it.failed.isNotEmpty()) {
                    "有 ${it.failed.size} 个源没响应"
                } else null
            }
            .onFailure { error = it.message }
        searching = false
        searched = true
    }

    LazyVerticalGrid(
        columns = GridCells.Fixed(3),
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = DvSpace.Gutter,
            end = DvSpace.Gutter,
            bottom = TabReserve,
        ),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(modifier = Modifier.padding(top = 10.dp)) {
                Text("搜索", style = DvType.PageTitle, color = p.text)
                Row(
                    modifier = Modifier
                        .padding(top = 11.dp)
                        .fillMaxWidth()
                        .height(36.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .background(p.surface)
                        .padding(horizontal = 11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    DvGlyph(DvGlyph.Search, tint = p.faint, sizeDp = 13)
                    Spacer(Modifier.width(7.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        textStyle = DvType.Caption.copy(color = p.text),
                        cursorBrush = SolidColor(p.accent),
                        modifier = Modifier.weight(1f),
                        decorationBox = { inner ->
                            Box {
                                if (query.isEmpty()) {
                                    Text(
                                        "搜索剧集、电影、演员",
                                        style = DvType.Caption,
                                        color = p.faint,
                                    )
                                }
                                inner()
                            }
                        },
                    )
                    if (query.isNotEmpty()) {
                        Text(
                            "清除",
                            style = DvType.Micro,
                            color = p.faint,
                            modifier = Modifier
                                .padding(start = 8.dp)
                                .clickableNoRipple { query = "" },
                        )
                    }
                }
            }
        }

        if (!searched) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(modifier = Modifier.padding(top = 16.dp)) {
                    Text(
                        "试试这些",
                        style = DvType.Micro,
                        color = p.faint,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        HotKeywords.take(3).forEach { word ->
                            DvPill(word, selected = false, onClick = { query = word })
                        }
                    }
                    Row(
                        modifier = Modifier.padding(top = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        HotKeywords.drop(3).forEach { word ->
                            DvPill(word, selected = false, onClick = { query = word })
                        }
                    }
                }
            }
        }

        if (searching && results.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) {
                    Text("搜索中…", style = DvType.Caption, color = p.faint)
                }
            }
        }

        if (searched && results.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) {
                    Text(
                        error ?: "没有找到「$query」",
                        style = DvType.Caption,
                        color = if (error != null) p.danger else p.faint,
                    )
                }
            }
        }

        if (results.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(
                    modifier = Modifier.padding(top = 6.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "${results.size} 个结果",
                        style = DvType.Micro,
                        color = p.faint,
                        fontWeight = FontWeight.Medium,
                    )
                    if (error != null) {
                        Spacer(Modifier.width(8.dp))
                        Text(error!!, style = DvType.Micro, color = p.warning)
                    }
                }
            }
            items(results, key = { it.id }) { item ->
                PosterCard(
                    item = item,
                    onClick = { onOpenDetail(item.id) },
                    fillWidth = true,
                )
            }
        }

        item(span = { GridItemSpan(maxLineSpan) }) { Spacer(Modifier.height(10.dp)) }
    }
}
