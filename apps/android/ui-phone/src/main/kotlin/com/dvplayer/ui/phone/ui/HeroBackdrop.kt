package com.dvplayer.ui.phone.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import com.dvplayer.design.DvTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 详情 / 首页的大图背景，照 macOS 的 `DetailPage.backdrop` 做：
 *
 * **一张图**，上半清晰、往下逐渐变模糊。清晰和模糊直接在位图里按行混合，
 * 画到屏幕上就是一张普通图片 —— 不再依赖运行时的 `BlendMode.DstIn` 离屏层
 * （API 28 那台机器上那层根本不显示，糊图和清晰图会叠成一张清晰图）。
 *
 * 上面再压一层黑渐变：顶部给返回按钮垫底，中段给白字垫底；最底下淡到页面底色。
 */
@Composable
fun HeroBackdrop(
    path: String?,
    modifier: Modifier = Modifier,
    /** 底边从哪一个高度开始淡向页面底色（0..1）。图越矮，越要早一点淡，不然会切出一条亮边。 */
    bottomFadeStart: Float = 0.68f,
    /** 从哪一个高度开始发虚（0..1）。首页 hero 想多露一点清楚的图，就把它往下调。 */
    blurStart: Float = 0.26f,
    /** 到哪一个高度完全糊掉（0..1）。 */
    blurEnd: Float = 0.68f,
    /**
     * 竖屏比横图窄很多，aspect-fill 会把画面两边裁掉一大块。
     * 打开后按宽度**完整**铺出整张图，图片下方用同一张图的模糊版接住，
     * 最后一段交叉淡化（详情页用）。
     */
    fitWhole: Boolean = false,
) {
    val repo = LocalRepo.current
    val p = DvTheme.palette
    var image by remember(path) { mutableStateOf<ImageBitmap?>(null) }

    BoxWithConstraints(modifier.background(p.surfaceAlt)) {
        val widthPx = constraints.maxWidth
        val heightPx = constraints.maxHeight

        LaunchedEffect(path, widthPx, heightPx, blurStart, blurEnd, fitWhole) {
            image = null
            val raw = path?.let { repo.bitmap(it) } ?: return@LaunchedEffect
            if (widthPx <= 0 || heightPx <= 0) return@LaunchedEffect
            image = withContext(Dispatchers.Default) {
                makeBackdrop(raw, widthPx, heightPx, blurStart, blurEnd, fitWhole)
            }
        }

        image?.let {
            Image(
                bitmap = it,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                // 位图已经按容器比例裁好，直接拉伸填满，不能再 Crop 一次（会把渐变位置弄错）。
                contentScale = ContentScale.FillBounds,
            )
        }

        // 压暗：顶部给返回按钮，中段给白字，底部继续加深。
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to Color.Black.copy(alpha = 0.34f),
                        0.18f to Color.Black.copy(alpha = 0.14f),
                        0.48f to Color.Black.copy(alpha = 0.28f),
                        0.62f to Color.Black.copy(alpha = 0.38f),
                        1f to Color.Black.copy(alpha = 0.46f),
                    ),
                ),
        )

        // 底边淡到页面底色。必须用「背景色的透明」，Color.Transparent 是黑色透明，
        // 插值到浅色背景会先变黑再变白，看着像一条硬缝。
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to p.background.copy(alpha = 0f),
                        bottomFadeStart to p.background.copy(alpha = 0f),
                        // macOS 首页 hero 的节奏：过了 0.68 就明显往底色走，0.84 之后基本是底色。
                        (bottomFadeStart + (1f - bottomFadeStart) * 0.55f) to
                            p.background.copy(alpha = 0.55f),
                        (bottomFadeStart + (1f - bottomFadeStart) * 0.86f) to
                            p.background.copy(alpha = 0.90f),
                        1f to p.background,
                    ),
                ),
        )
    }
}

/**
 * 把源图铺成容器大小，上半清晰、下半模糊。
 *
 * 裁剪以顶部对齐（不是居中）：手机上容器比图窄，居中会把顶部一起裁掉，
 * 看着像「图上少了一块」。
 */
private fun makeBackdrop(
    src: Bitmap,
    targetW: Int,
    targetH: Int,
    blurStart: Float,
    blurEnd: Float,
    fitWhole: Boolean,
): ImageBitmap {
    if (targetW <= 0 || targetH <= 0) return src.asImageBitmap()

    // 到屏幕宽度就够了（再大是白占内存）。
    val baseW = min(targetW, 720).coerceAtLeast(1)
    val baseH = (baseW.toFloat() * targetH / targetW).roundToInt().coerceAtLeast(1)

    val cover = scaleCover(src, baseW, baseH)
    if (!fitWhole) {
        val bg = blur(cover, baseW, baseH)
        val mixed = mixRows(cover, bg, baseW, baseH, blurStart, blurEnd)
        // 中间图用完就放：一台 2G 内存的机器上，几张整屏位图叠在一起很容易 OOM。
        cover.recycle()
        bg.recycle()
        return mixed.asImageBitmap()
    }
    cover.recycle()

    // 完整图：宽度铺满，高度按原图比例。它下面接的不是「另一套裁切」，
    // 而是**同一张图**本身：整张图竖直铺满容器、再重度糊掉，当成氛围色。
    //
    // 照 macOS `DetailPage.backdrop` 的思路（清晰层和模糊层同源、同几何），
    // 这里也保证两层在同一像素位置对得上：图片下半段把清晰图渐变到模糊层，
    // 到图片底边时 100% 是模糊层那一行的颜色，下面的延伸从同一行接着往下画，
    // 所以交界处既不变色也不跳，看不到「两张图」。
    val fitH = (src.height.toFloat() * baseW / src.width).roundToInt().coerceIn(1, baseH)
    if (fitH >= baseH) {
        // 图本来就比容器还高（竖版海报）：直接走 cover 那套。
        val coverFull = scaleCover(src, baseW, baseH)
        val bg = blur(coverFull, baseW, baseH)
        val mixed = mixRows(coverFull, bg, baseW, baseH, blurStart, blurEnd)
        coverFull.recycle()
        bg.recycle()
        return mixed.asImageBitmap()
    }
    val fit = Bitmap.createScaledBitmap(src, baseW, fitH, true)
    val ambient = ambientBlur(src, baseW, baseH)
    val mixed = fitThenAmbient(fit, ambient, baseW, baseH, blurStart)
    fit.recycle()
    ambient.recycle()
    return mixed.asImageBitmap()
}

/**
 * 整张图竖直铺满容器后重度模糊：只剩这张图的颜色分布，没有任何轮廓。
 * 缩到 20 像素宽再放大，等于一个超大的双线性采样。
 */
private fun ambientBlur(src: Bitmap, w: Int, h: Int): Bitmap {
    val stretched = Bitmap.createScaledBitmap(src, w, h, true)
    val smallW = min(12, w)
    val smallH = (h.toFloat() * smallW / w).roundToInt().coerceAtLeast(1)
    val small = Bitmap.createScaledBitmap(stretched, smallW, smallH, true)
    stretched.recycle()
    val px = IntArray(smallW * smallH)
    small.getPixels(px, 0, smallW, 0, 0, smallW, smallH)
    val tmp = IntArray(smallW * smallH)
    val out = IntArray(smallW * smallH)
    blurAxis(px, tmp, smallW, smallH, radius = 2, horizontal = true)
    blurAxis(tmp, out, smallW, smallH, radius = 2, horizontal = false)
    val blurred = Bitmap.createBitmap(out, smallW, smallH, Bitmap.Config.ARGB_8888)
    val scaled = Bitmap.createScaledBitmap(blurred, w, h, true)
    small.recycle()
    blurred.recycle()
    return scaled
}

/**
 * 上部贴清晰图，下部贴 [ambient]；图片从 [blurStart] 开始渐变到 [ambient] 上同一
 * 位置的像素，所以两张图在拼接处颜色完全相同（看不到接缝）。
 */
private fun fitThenAmbient(
    fit: Bitmap,
    ambient: Bitmap,
    w: Int,
    h: Int,
    blurStart: Float,
): Bitmap {
    val fitH = min(fit.height, h)
    val out = IntArray(w * h)
    val ambPx = IntArray(w * h)
    ambient.getPixels(ambPx, 0, w, 0, 0, w, h)

    // 渐变区从 `blurStart` 开始（相对图片高度），越往下越糊；到图片底边
    // 100% 是氛围色，下面的延伸从同一行接着画，所以交界处看不出来。
    val startRatio = blurStart.coerceIn(0.5f, 0.98f)
    val fadeStart = (fitH * startRatio).toInt().coerceIn(0, fitH)
    val fadeRows = (fitH - fadeStart).coerceAtLeast(1)
    // 只取上部：下部整段就是氛围色，不用逐张 getPixels。
    for (y in 0 until fitH) {
        val row = y * w
        if (y < fadeStart) {
            fit.getPixels(out, row, w, 0, y, w, 1)
            continue
        }
        val t = (y - fadeStart).toFloat() / fadeRows
        val k = t * t * (3f - 2f * t)
        val sharp = IntArray(w)
        fit.getPixels(sharp, 0, w, 0, y, w, 1)
        for (x in 0 until w) out[row + x] = blendPx(sharp[x], ambPx[row + x], k)
    }
    for (y in fitH until h) {
        System.arraycopy(ambPx, y * w, out, y * w, w)
    }
    return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
}

private fun blendPx(from: Int, to: Int, k: Float): Int {
    val r = (((from shr 16) and 0xFF) * (1f - k) + ((to shr 16) and 0xFF) * k).toInt()
    val g = (((from shr 8) and 0xFF) * (1f - k) + ((to shr 8) and 0xFF) * k).toInt()
    val b = ((from and 0xFF) * (1f - k) + (to and 0xFF) * k).toInt()
    return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
}

/** center-crop（垂直方向贴顶）到目标尺寸。 */
private fun scaleCover(src: Bitmap, w: Int, h: Int): Bitmap {
    val scale = max(w.toFloat() / src.width, h.toFloat() / src.height)
    val cropW = (w / scale).roundToInt().coerceIn(1, src.width)
    val cropH = (h / scale).roundToInt().coerceIn(1, src.height)
    val cropX = ((src.width - cropW) / 2).coerceAtLeast(0)
    val cropY = 0
    val cropped = Bitmap.createBitmap(src, cropX, cropY, cropW, cropH)
    return Bitmap.createScaledBitmap(cropped, w, h, true)
}

/** 缩到 96 宽再盒式模糊，放大回来就是一团柔和的色块。 */
private fun blur(src: Bitmap, w: Int, h: Int): Bitmap {
    val smallW = min(96, w)
    val smallH = (h.toFloat() * smallW / w).roundToInt().coerceAtLeast(1)
    val small = Bitmap.createScaledBitmap(src, smallW, smallH, true)
    val pixels = IntArray(smallW * smallH)
    small.getPixels(pixels, 0, smallW, 0, 0, smallW, smallH)
    val temp = IntArray(smallW * smallH)
    val blurredSmall = IntArray(smallW * smallH)
    blurAxis(pixels, temp, smallW, smallH, radius = 4, horizontal = true)
    blurAxis(temp, blurredSmall, smallW, smallH, radius = 4, horizontal = false)
    return Bitmap
        .createBitmap(blurredSmall, smallW, smallH, Bitmap.Config.ARGB_8888)
        .let { Bitmap.createScaledBitmap(it, w, h, true) }
}

/** 按行混合：`blurStart` 之前清晰，`blurEnd` 之后全糊，中间 smoothstep。 */
private fun mixRows(
    sharp: Bitmap,
    blurred: Bitmap,
    w: Int,
    h: Int,
    blurStart: Float,
    blurEnd: Float,
): Bitmap {
    val sharpPx = IntArray(w * h)
    sharp.getPixels(sharpPx, 0, w, 0, 0, w, h)
    val blurPx = IntArray(w * h)
    blurred.getPixels(blurPx, 0, w, 0, 0, w, h)

    val out = IntArray(w * h)
    for (y in 0 until h) {
        val t = ((y.toFloat() / h - blurStart) / (blurEnd - blurStart).coerceAtLeast(0.01f))
            .coerceIn(0f, 1f)
        if (t <= 0f) {
            System.arraycopy(sharpPx, y * w, out, y * w, w)
            continue
        }
        if (t >= 1f) {
            System.arraycopy(blurPx, y * w, out, y * w, w)
            continue
        }
        val k = t * t * (3f - 2f * t)
        val offset = y * w
        for (x in 0 until w) {
            val s = sharpPx[offset + x]
            val b = blurPx[offset + x]
            val a = (s ushr 24) + (((b ushr 24) - (s ushr 24)) * k).toInt()
            val r = ((s shr 16) and 0xFF) + ((((b shr 16) and 0xFF) - ((s shr 16) and 0xFF)) * k).toInt()
            val g = ((s shr 8) and 0xFF) + ((((b shr 8) and 0xFF) - ((s shr 8) and 0xFF)) * k).toInt()
            val bl = (s and 0xFF) + (((b and 0xFF) - (s and 0xFF)) * k).toInt()
            out[offset + x] = (a shl 24) or (r shl 16) or (g shl 8) or bl
        }
    }
    return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
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
