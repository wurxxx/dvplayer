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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.dvplayer.core.MediaItem
import com.dvplayer.core.PlayRecord
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.LocalDvWindow
import com.dvplayer.design.TabReserve
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.ui.PosterCard
import com.dvplayer.ui.phone.ui.WideCard

/**
 * 观看 tab：继续观看 + 收藏。
 *
 * 「继续观看」用 `records()`——那是核心按 `lastPlayed` 排好的播放记录，
 * 比从每个库里筛进度更准（跨源也能拼在一起）。
 */
@Composable
fun WatchScreen(
    repo: PhoneRepository,
    onPlay: (String, String?) -> Unit,
    onOpenDetail: (String) -> Unit,
    revision: Int = 0,
) {
    val p = DvTheme.palette
    var records by remember { mutableStateOf<List<PlayRecord>>(emptyList()) }
    var favorites by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(revision) {
        records = runCatching { repo.records() }.getOrDefault(emptyList())
        favorites = runCatching { repo.favorites() }.getOrNull()?.items.orEmpty()
        loaded = true
    }

    LazyVerticalGrid(
        columns = GridCells.Fixed(LocalDvWindow.current.gridColumns()),
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
            Column {
                Text(
                    "观看",
                    style = DvType.PageTitle,
                    color = p.text,
                    modifier = Modifier.padding(top = 10.dp),
                )
                Text(
                    "继续播放没看完的，或从收藏里挑一部",
                    style = DvType.Micro,
                    color = p.faint,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }

        if (records.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(
                    modifier = Modifier.padding(top = 16.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("继续观看", style = DvType.SectionTitle, color = p.text)
                    Spacer(Modifier.width(6.dp))
                    Text("${records.size}", style = DvType.Micro, color = p.faint)
                }
            }
            // 横排要占满整行，用 Row 包一层横向滚动而不是 LazyRow（网格里放不了 LazyRow 的高度）。
            item(span = { GridItemSpan(maxLineSpan) }) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(records, key = { it.itemId }) { record ->
                        WideCard(
                            record = record,
                            onClick = { onPlay(record.itemId, record.parentId) },
                            width = 186.dp,
                        )
                    }
                }
            }
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(
                modifier = Modifier.padding(top = 18.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("收藏", style = DvType.SectionTitle, color = p.text)
                Spacer(Modifier.width(6.dp))
                Text(
                    if (favorites.isEmpty()) "" else "${favorites.size}",
                    style = DvType.Micro,
                    color = p.faint,
                )
            }
        }

        if (loaded && favorites.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(vertical = 28.dp), contentAlignment = Alignment.Center) {
                    Text("还没有收藏。详情页点「收藏」就会出现在这里。", style = DvType.Caption, color = p.faint)
                }
            }
        }

        items(favorites, key = { it.id }) { item ->
            PosterCard(
                item = item,
                onClick = { onOpenDetail(item.id) },
                fillWidth = true,
            )
        }

        item(span = { GridItemSpan(maxLineSpan) }) { Spacer(Modifier.height(10.dp)) }
    }
}
