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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.ListQuery
import com.dvplayer.core.MediaItem
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.TabReserve
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.ui.phone.data.PhoneRepository
import com.dvplayer.ui.phone.ui.DvPill
import com.dvplayer.ui.phone.ui.ScreenHeader
import com.dvplayer.ui.phone.ui.cleanTitle
import com.dvplayer.ui.phone.ui.PosterCard
import kotlinx.coroutines.launch

private val SortOptions = listOf(
    "added" to "最近添加",
    "name" to "名称",
    "rating" to "评分",
    "release" to "年份",
)

/**
 * 分类列表：一个库里的全部条目。
 *
 * 排序走 `ListQuery.sort`（核心只支持 added / name / rating / release 四种）。
 * 分页 60 一条，滚到底部继续取——Emby 上一个库几百部很正常，一次拉完要等太久。
 */
@Composable
fun CategoryScreen(
    repo: PhoneRepository,
    sourceId: String,
    libraryId: String,
    title: String,
    onBack: () -> Unit,
    onOpenDetail: (String) -> Unit,
) {
    val p = DvTheme.palette
    val scope = rememberCoroutineScope()

    var items by remember(libraryId) { mutableStateOf<List<MediaItem>>(emptyList()) }
    var total by remember(libraryId) { mutableStateOf(0L) }
    var page by remember(libraryId) { mutableStateOf(1) }
    var sort by remember(libraryId) { mutableStateOf("added") }
    var desc by remember(libraryId) { mutableStateOf(true) }
    var loading by remember(libraryId) { mutableStateOf(true) }
    var hasMore by remember(libraryId) { mutableStateOf(false) }
    var error by remember(libraryId) { mutableStateOf<String?>(null) }

    LaunchedEffect(libraryId, sort, desc) {
        loading = true
        error = null
        val res = runCatching {
            repo.items(libraryId, page = 1, pageSize = 60, query = ListQuery(sort = sort, descending = desc))
        }
        res.onSuccess {
            items = it.items
            total = it.total
            hasMore = it.hasMore
            page = 1
        }.onFailure {
            error = it.message
        }
        loading = false
    }

    fun loadMore() {
        if (loading || !hasMore) return
        scope.launch {
            loading = true
            runCatching {
                repo.items(libraryId, page = page + 1, pageSize = 60, query = ListQuery(sort = sort, descending = desc))
            }.onSuccess {
                items = items + it.items
                page += 1
                hasMore = it.hasMore
            }
            loading = false
        }
    }

    LazyVerticalGrid(
        // 照 macOS 的浏览页：标题 + 筛选 + 海报网格，没有大图 hero。
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
            ScreenHeader(
                title = cleanTitle(title),
                subtitle = buildString {
                    if (total > 0) append("$total 部")
                    if (total > 0) append(" · ")
                    append(SortOptions.firstOrNull { it.first == sort }?.second.orEmpty())
                },
                onBack = onBack,
            )
        }

        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(bottom = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SortOptions.forEach { (value, label) ->
                    DvPill(
                        text = label,
                        selected = sort == value,
                        onClick = { sort = value },
                    )
                }
                Spacer(Modifier.width(2.dp))
                DvPill(
                    text = if (desc) "降序" else "升序",
                    selected = false,
                    onClick = { desc = !desc },
                )
            }
        }

            if (error != null) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Box(Modifier.fillMaxWidth().padding(28.dp), contentAlignment = Alignment.Center) {
                        Text("加载失败：$error", style = DvType.Caption, color = p.danger)
                    }
                }
            }

            if (items.isEmpty() && !loading && error == null) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Box(Modifier.fillMaxWidth().padding(36.dp), contentAlignment = Alignment.Center) {
                        Text("这个库里还没有条目", style = DvType.Caption, color = p.faint)
                    }
                }
            }

            items(items, key = { it.id }) { item ->
                PosterCard(
                    item = item,
                    onClick = { onOpenDetail(item.id) },
                    fillWidth = true,
                )
            }

            if (hasMore) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 14.dp)
                            .clickableNoRipple { loadMore() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            if (loading) "加载中…" else "加载更多",
                            style = DvType.Caption,
                            color = p.accent,
                        )
                    }
                }
            }

            item(span = { GridItemSpan(maxLineSpan) }) {
                Spacer(Modifier.height(8.dp))
            }
    }
}
