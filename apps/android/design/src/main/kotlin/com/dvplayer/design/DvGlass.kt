package com.dvplayer.design

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

data class DvTab(val label: String, val glyph: DvGlyph)

/** 背景抓图降采样倍数：4 倍后 720×1280 变成 180×320，保留色块、丢掉细节。 */
private const val BackdropDivisor = 4

/** 抓图间隔。慢一点没关系——玻璃后面是静态内容时看不出来，滚动时本来就是糊的。 */
private const val BackdropIntervalMs = 800L

/**
 * 抓内容层 → 降采样 → 模糊，给 tab 当玻璃背景。
 *
 * 关键是不能连 tab 自己一起抓：否则 backgrounds 里会混进 tab 的白雾，再叠一次白，
 * 几百毫秒后整条 tab 就糊成一片死白，背后什么颜色都没有。所以内容单独放在一个
 * `GraphicsLayer` 里，抓的是这一层。
 *
 * Android 10 以下没有 `RenderEffect`，模糊自己做：先 4 倍降采样（盒式平均），再两趟
 * 盒式模糊。降采样本身已经丢掉细节，糊一次就是参考图那种磨砂感。
 */
@Composable
private fun rememberGlassBackdrop(
    layer: GraphicsLayer?,
    enabled: Boolean,
    resetKey: Any?,
): ImageBitmap? {
    var backdrop by remember { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(layer, enabled, resetKey) {
        // 换页面时先清掉：否则要等下一张抓图，中间那 650ms 玻璃里还是上一页的颜色。
        backdrop = null
        if (layer == null || !enabled) {
            return@LaunchedEffect
        }
        while (true) {
            delay(BackdropIntervalMs)
            val image = runCatching { layer.toImageBitmap() }.getOrNull() ?: continue
            val blurred = withContext(Dispatchers.Default) { blurDownscaled(image) }
            if (blurred != null) backdrop = blurred.asImageBitmap()
        }
    }
    return backdrop
}

private fun blurDownscaled(image: ImageBitmap): Bitmap? = runCatching {
    val w = image.width
    val h = image.height
    if (w <= 0 || h <= 0) return@runCatching null
    val pixels = IntArray(w * h)
    image.readPixels(pixels)
    val (small, sw, sh) = downscale(pixels, w, h, BackdropDivisor)
    val blurred = IntArray(small.size)
    blurAxis(small, blurred, sw, sh, radius = 6, horizontal = true)
    val out = IntArray(small.size)
    blurAxis(blurred, out, sw, sh, radius = 6, horizontal = false)
    Bitmap.createBitmap(out, sw, sh, Bitmap.Config.ARGB_8888)
}.getOrNull()

/** 4×4 盒式平均降采样。 */
private fun downscale(src: IntArray, sw: Int, sh: Int, factor: Int): Triple<IntArray, Int, Int> {
    val dw = (sw / factor).coerceAtLeast(1)
    val dh = (sh / factor).coerceAtLeast(1)
    val out = IntArray(dw * dh)
    for (y in 0 until dh) {
        for (x in 0 until dw) {
            var a = 0
            var r = 0
            var g = 0
            var b = 0
            var n = 0
            for (dy in 0 until factor) {
                val sy = y * factor + dy
                if (sy >= sh) break
                val row = sy * sw
                for (dx in 0 until factor) {
                    val sx = x * factor + dx
                    if (sx >= sw) break
                    val px = src[row + sx]
                    a += px ushr 24
                    r += (px shr 16) and 0xFF
                    g += (px shr 8) and 0xFF
                    b += px and 0xFF
                    n++
                }
            }
            if (n == 0) continue
            out[y * dw + x] =
                ((a / n) shl 24) or ((r / n) shl 16) or ((g / n) shl 8) or (b / n)
        }
    }
    return Triple(out, dw, dh)
}

private fun blurAxis(
    src: IntArray,
    dst: IntArray,
    w: Int,
    h: Int,
    radius: Int,
    horizontal: Boolean,
) {
    val outer = if (horizontal) h else w
    val inner = if (horizontal) w else h
    val stride = if (horizontal) 1 else w
    val window = 2 * radius + 1

    for (o in 0 until outer) {
        val base = if (horizontal) o * w else o
        var a = 0
        var r = 0
        var g = 0
        var b = 0
        for (i in -radius..radius) {
            val px = src[base + i.coerceIn(0, inner - 1) * stride]
            a += px ushr 24
            r += (px shr 16) and 0xFF
            g += (px shr 8) and 0xFF
            b += px and 0xFF
        }
        for (i in 0 until inner) {
            dst[base + i * stride] =
                ((a / window) shl 24) or
                    ((r / window) shl 16) or
                    ((g / window) shl 8) or
                    (b / window)
            val outPx = src[base + (i - radius).coerceIn(0, inner - 1) * stride]
            val inPx = src[base + (i + radius + 1).coerceIn(0, inner - 1) * stride]
            a += (inPx ushr 24) - (outPx ushr 24)
            r += ((inPx shr 16) and 0xFF) - ((outPx shr 16) and 0xFF)
            g += ((inPx shr 8) and 0xFF) - ((outPx shr 8) and 0xFF)
            b += (inPx and 0xFF) - (outPx and 0xFF)
        }
    }
}

/**
 * 浮空玻璃 tab 条。
 *
 * 造型照参考图：一条悬浮胶囊 + 右侧一个独立的圆形按钮（分离出来的 tab）。
 * 玻璃背景是抓取内容后真模糊出来的位图，按各自在窗口里的位置采样；
 * 上面再压一层雾化底色，外加细边和一档柔和阴影，让它浮在内容上。
 */
@Composable
fun DvGlassTabBar(
    tabs: List<DvTab>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    backdrop: ImageBitmap? = null,
    /** 这个下标的 tab 不放在胶囊里，单独做成右侧的圆形按钮（参考图的搜索）。 */
    detached: Int? = null,
) {
    val p = DvTheme.palette
    val shape = RoundedCornerShape(percent = 50)
    // 雾化层：浅色压白、深色压暗，让文字在任何海报上都读得清，同时保留背后颜色的形状。
    val fog = if (p.isDark) p.surfaceAlt.copy(alpha = 0.80f) else Color.White.copy(alpha = 0.74f)
    val edge = if (p.isDark) Color.White.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.85f)

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GlassPill(
            backdrop = backdrop,
            fog = fog,
            edge = edge,
            shape = shape,
            modifier = Modifier.weight(1f).height(DvSpace.TabHeight),
        ) {
            Row(
                modifier = Modifier.fillMaxSize().padding(horizontal = 5.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                tabs.forEachIndexed { index, tab ->
                    if (index == detached) return@forEachIndexed
                    TabItem(
                        tab = tab,
                        selected = index == selected,
                        onClick = { onSelect(index) },
                        modifier = Modifier.weight(1f).fillMaxSize(),
                    )
                }
            }
        }

        if (detached != null) {
            Spacer(Modifier.width(9.dp))
            GlassPill(
                backdrop = backdrop,
                fog = fog,
                edge = edge,
                shape = CircleShape,
                modifier = Modifier.size(DvSpace.TabHeight),
            ) {
                TabItem(
                    tab = tabs[detached],
                    selected = detached == selected,
                    onClick = { onSelect(detached) },
                    iconOnly = true,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

/** 一块「玻璃」：模糊背景 + 雾 + 细边 + 阴影，胶囊和圆钮共用。 */
@Composable
private fun GlassPill(
    backdrop: ImageBitmap?,
    fog: Color,
    edge: Color,
    shape: Shape,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val view = LocalView.current
    var windowOffset by remember { mutableStateOf(Offset.Zero) }

    Box(
        modifier = modifier
            .shadow(
                elevation = 18.dp,
                shape = shape,
                clip = false,
                ambientColor = Color.Black.copy(alpha = 0.18f),
                spotColor = Color.Black.copy(alpha = 0.30f),
            )
            .onGloballyPositioned { coords ->
                windowOffset = coords.positionInWindow()
            }
            .clip(shape)
            .drawBehind {
                val bitmap = backdrop
                val windowWidth = view.width
                if (bitmap != null && windowWidth > 0) {
                    val ratio = bitmap.width.toFloat() / windowWidth
                    val srcX = (windowOffset.x * ratio).roundToInt().coerceAtLeast(0)
                    val srcY = (windowOffset.y * ratio).roundToInt().coerceAtLeast(0)
                    val srcW = (size.width * ratio).roundToInt().coerceAtLeast(1)
                    val srcH = (size.height * ratio).roundToInt().coerceAtLeast(1)
                    if (srcX + srcW <= bitmap.width && srcY + srcH <= bitmap.height) {
                        drawImage(
                            image = bitmap,
                            srcOffset = IntOffset(srcX, srcY),
                            srcSize = IntSize(srcW, srcH),
                            dstOffset = IntOffset.Zero,
                            dstSize = IntSize(size.width.toInt(), size.height.toInt()),
                            filterQuality = FilterQuality.High,
                        )
                    }
                }
                drawRect(fog)
            }
            .border(1.dp, edge, shape),
        content = content,
    )
}

@Composable
private fun TabItem(
    tab: DvTab,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    iconOnly: Boolean = false,
) {
    val p = DvTheme.palette
    // 雾是浅色时用正文色：未选中的图标 / 文字要压得住，不能灰成一团。
    val tint = if (selected) p.accent else if (p.isDark) p.subtle else p.text.copy(alpha = 0.80f)
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(percent = 50))
            .clickableNoRipple(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            DvGlyph(
                glyph = tab.glyph,
                tint = tint,
                sizeDp = if (iconOnly) 24 else 23,
                strokeWidth = if (selected) 0.080f else 0.060f,
            )
            if (!iconOnly) {
                Text(
                    text = tab.label,
                    color = tint,
                    fontSize = DvType.Micro.fontSize,
                    lineHeight = 13.sp,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                )
            }
        }
    }
}

/** 没有涟漪：这个 App 的按钮用透明度变化回应，涟漪会破坏干净的观感。 */
fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier = this.composed {
    val source = remember { MutableInteractionSource() }
    this.clickable(interactionSource = source, indication = null, onClick = onClick)
}

/**
 * 内容页骨架：背景 + 内容 + 浮空 tab。
 *
 * tab 悬浮在内容之上（不占布局高度），所以内容要自己留出底部空间。
 * 内容层每 650ms 被抓一张小图给 tab 当玻璃背景；tab 收起时停止抓，省电。
 */
@Composable
fun DvScaffold(
    tabs: List<DvTab>,
    selectedTab: Int,
    onTab: (Int) -> Unit,
    modifier: Modifier = Modifier,
    showTab: Boolean = true,
    /** 页面标识：变了就清一次玻璃底，避免切页瞬间残留上一页的颜色。 */
    backdropKey: Any? = null,
    /** 顶部呼吸空间。有大图 hero 的页面要传 false，让图从屏幕最顶上开始铺。 */
    topInset: Boolean = true,
    /** 这个下标的 tab 从胶囊里拿出来，做成右侧的圆形按钮。 */
    detachedTab: Int? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val p = DvTheme.palette
    val density = LocalDensity.current
    // 全屏时状态栏 inset 是 0，标题会直接贴到屏幕最上沿；留一点固定呼吸。
    val statusTop = WindowInsets.statusBars.getTop(density)
    val topPad = when {
        !topInset -> 0.dp
        statusTop > 0 -> with(density) { statusTop.toDp() }
        else -> 12.dp
    }
    val contentLayer = rememberGraphicsLayer()
    val backdrop = rememberGlassBackdrop(
        layer = contentLayer,
        enabled = showTab,
        resetKey = backdropKey,
    )

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        // 断点只认窗口宽度：分屏、折叠屏展开、桌面窗口拖动都会重新量。
        val window = DvWindow(maxWidth, maxHeight)
        CompositionLocalProvider(LocalDvWindow provides window) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(p.background)
                    .padding(top = topPad),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        // 宽屏换成左侧竖排胶囊：内容让出它的位置，hero 不会钻到轨道下面。
                        .padding(start = if (window.medium) DvSpace.RailReserve else 0.dp)
                        .drawWithContent {
                            contentLayer.record {
                                this@drawWithContent.drawContent()
                            }
                            drawLayer(contentLayer)
                        },
                ) {
                    content()
                }
                if (showTab) {
                    if (window.medium) {
                        DvGlassRail(
                            tabs = tabs,
                            selected = selectedTab,
                            onSelect = onTab,
                            backdrop = backdrop,
                            modifier = Modifier
                                .align(Alignment.CenterStart)
                                .navigationBarsPadding()
                                .padding(start = 12.dp),
                        )
                    } else {
                        DvGlassTabBar(
                            tabs = tabs,
                            selected = selectedTab,
                            onSelect = onTab,
                            backdrop = backdrop,
                            detached = detachedTab,
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .navigationBarsPadding()
                                .padding(start = 16.dp, end = 16.dp, bottom = 10.dp),
                        )
                    }
                }
            }
        }
    }
}

/**
 * 宽屏左侧的竖排玻璃胶囊。
 *
 * 底部条在平板上会被摊成一根长条（三个页签分到屏幕两端），而且仍然浮在内容上；
 * 竖排之后只占 76dp，`TabReserve` 也随之变成一小段留白。
 */
@Composable
private fun DvGlassRail(
    tabs: List<DvTab>,
    selected: Int,
    onSelect: (Int) -> Unit,
    backdrop: ImageBitmap?,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    val fog = if (p.isDark) p.surfaceAlt.copy(alpha = 0.86f) else Color.White.copy(alpha = 0.82f)
    val edge = if (p.isDark) Color.White.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.85f)

    GlassPill(
        backdrop = backdrop,
        fog = fog,
        edge = edge,
        shape = RoundedCornerShape(percent = 50),
        modifier = modifier.width(DvSpace.RailWidth),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp, horizontal = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            tabs.forEachIndexed { index, tab ->
                RailItem(
                    tab = tab,
                    selected = index == selected,
                    onClick = { onSelect(index) },
                    modifier = Modifier.fillMaxWidth().height(DvSpace.RailItemHeight),
                )
            }
        }
    }
}

@Composable
private fun RailItem(
    tab: DvTab,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = DvTheme.palette
    val tint = if (selected) p.accent else if (p.isDark) p.subtle else p.text.copy(alpha = 0.80f)
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(percent = 50))
            .clickableNoRipple(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        DvGlyph(
            glyph = tab.glyph,
            tint = tint,
            sizeDp = 21,
            strokeWidth = if (selected) 0.080f else 0.060f,
        )
        Text(
            text = tab.label,
            color = tint,
            fontSize = DvType.Micro.fontSize,
            lineHeight = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            modifier = Modifier.padding(top = 3.dp),
        )
    }
}

/**
 * 内容底部要给浮空 tab 留出的空间。
 *
 * edge-to-edge 之后 tab 还会被导航栏顶起来，所以这里要把导航栏高度算进去，
 * 否则列表最后一条会压在 tab 后面。
 * 宽屏的 tab 在左侧竖排，底部只需要一小段呼吸。
 */
val TabReserve: Dp
    @Composable get() = if (LocalDvWindow.current.medium) {
        24.dp
    } else {
        (DvSpace.TabHeight + DvSpace.TabInset * 2 + 12.dp) +
            with(LocalDensity.current) {
                WindowInsets.navigationBars.getBottom(this).toDp()
            }
    }
