package com.dvplayer.ui.phone.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvTheme
import com.dvplayer.ui.phone.data.PhoneRepository

val LocalRepo = staticCompositionLocalOf<PhoneRepository> { error("PhoneRepository 未提供") }

/**
 * 播放页的剧照加载器。
 *
 * 播放页不在 `PhoneApp` 的树里，拿不到 [LocalRepo]；由播放 Activity 把
 * [PhoneRepository.bitmap] 包成 lambda 提供进来。没提供时剧照退回占位色块。
 */
val LocalStillLoader = staticCompositionLocalOf<(suspend (String) -> android.graphics.Bitmap?)?> { null }

/**
 * 远程海报。
 *
 * 图片要现取：`imageSource(path)` 给出的是带 token 的 URL，只有核心知道怎么拼。
 * 解码结果进 `PhoneRepository` 的 LruCache，滚动回来不再走网络。
 */
@Composable
fun RemoteImage(
    path: String?,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
    drawPlaceholder: Boolean = true,
) {
    val repo = LocalRepo.current
    val p = DvTheme.palette
    var bitmap by remember(path) { mutableStateOf<android.graphics.Bitmap?>(null) }

    LaunchedEffect(path) {
        if (path == null) {
            bitmap = null
        } else {
            bitmap = repo.bitmap(path)
        }
    }

    Box(
        modifier = if (drawPlaceholder) {
            modifier.background(Brush.linearGradient(listOf(p.surfaceAlt, p.surface)))
        } else {
            modifier
        },
    ) {
        if (bitmap == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                DvGlyph(
                    glyph = DvGlyph.Media,
                    tint = p.faint.copy(alpha = 0.32f),
                    sizeDp = 18,
                )
            }
        }
        bitmap?.let {
            Image(
                bitmap = it.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = contentScale,
            )
        }
    }
}
