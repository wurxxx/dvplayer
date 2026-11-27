package com.dvplayer.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/**
 * 内容页的线性图标。
 *
 * 和播放页的 `DvIcon` 同一套画法（0.075u 线宽、圆头圆角），但不共用文件：
 * 那些是播放控件专用，这些是导航 / 列表 / 详情操作。用 Canvas 画而不是引
 * `material-icons-extended`，理由同 DvIcon——那套在 Compose 1.8 之后停更。
 */
enum class DvGlyph {
    Media, Watch, Search, Settings,
    Back, ChevronRight, More, Refresh, Plus,
    Heart, HeartFilled, CheckCircle, Restart,
    Audio, Subtitle, Trakt, Grid, ListRows, Filter, Sort, Play,
    Folder, Star, Link,
}

@Composable
fun DvGlyph(
    glyph: DvGlyph,
    modifier: Modifier = Modifier,
    tint: Color = Color.White,
    sizeDp: Int = 18,
    strokeWidth: Float = 0.075f,
) {
    Canvas(modifier = modifier.size(sizeDp.dp)) {
        val u = size.minDimension
        val stroke = Stroke(width = u * strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round)
        drawGlyph(glyph, tint, u, stroke)
    }
}

private fun DrawScope.drawGlyph(glyph: DvGlyph, c: Color, u: Float, stroke: Stroke) {
    fun line(x1: Float, y1: Float, x2: Float, y2: Float, width: Float = stroke.width) =
        drawLine(c, Offset(u * x1, u * y1), Offset(u * x2, u * y2), width, StrokeCap.Round)

    fun rect(x: Float, y: Float, w: Float, h: Float, r: Float, filled: Boolean = false) =
        drawRoundRect(
            color = c,
            topLeft = Offset(u * x, u * y),
            size = Size(u * w, u * h),
            cornerRadius = CornerRadius(u * r),
            style = if (filled) androidx.compose.ui.graphics.drawscope.Fill else stroke,
        )

    fun path(filled: Boolean = false, build: Path.() -> Unit) =
        drawPath(Path().apply(build), c, style = if (filled) androidx.compose.ui.graphics.drawscope.Fill else stroke)

    when (glyph) {
        DvGlyph.Media -> {
            rect(0.12f, 0.24f, 0.76f, 0.52f, 0.10f)
            path(filled = true) {
                moveTo(u * 0.42f, u * 0.39f)
                lineTo(u * 0.62f, u * 0.50f)
                lineTo(u * 0.42f, u * 0.61f)
                close()
            }
        }
        DvGlyph.Watch -> {
            rect(0.12f, 0.24f, 0.76f, 0.52f, 0.10f)
            line(0.34f, 0.24f, 0.34f, 0.76f)
            line(0.66f, 0.24f, 0.66f, 0.76f)
        }
        DvGlyph.Search -> {
            drawCircle(c, u * 0.21f, Offset(u * 0.45f, u * 0.45f), style = stroke)
            line(0.61f, 0.61f, 0.80f, 0.80f)
        }
        DvGlyph.Settings -> {
            drawCircle(c, u * 0.235f, center, style = stroke)
            drawCircle(c, u * 0.075f, center)
            for (i in 0 until 8) {
                val a = Math.toRadians(i * 45.0)
                val cos = Math.cos(a).toFloat()
                val sin = Math.sin(a).toFloat()
                line(
                    0.5f + cos * 0.225f, 0.5f + sin * 0.225f,
                    0.5f + cos * 0.335f, 0.5f + sin * 0.335f,
                    stroke.width * 1.45f,
                )
            }
        }
        DvGlyph.Link -> {
            drawArc(
                color = c,
                startAngle = -45f,
                sweepAngle = 180f,
                useCenter = false,
                topLeft = Offset(u * 0.08f, u * 0.26f),
                size = Size(u * 0.46f, u * 0.46f),
                style = stroke,
            )
            drawArc(
                color = c,
                startAngle = 135f,
                sweepAngle = 180f,
                useCenter = false,
                topLeft = Offset(u * 0.46f, u * 0.26f),
                size = Size(u * 0.46f, u * 0.46f),
                style = stroke,
            )
        }
        DvGlyph.Back -> path {
            moveTo(u * 0.61f, u * 0.27f)
            lineTo(u * 0.37f, u * 0.50f)
            lineTo(u * 0.61f, u * 0.73f)
        }
        DvGlyph.ChevronRight -> path {
            moveTo(u * 0.43f, u * 0.28f)
            lineTo(u * 0.61f, u * 0.50f)
            lineTo(u * 0.43f, u * 0.72f)
        }
        DvGlyph.More -> for (x in listOf(0.28f, 0.50f, 0.72f)) {
            drawCircle(c, u * 0.055f, Offset(u * x, u * 0.5f))
        }
        DvGlyph.Refresh -> {
            val r = 0.31f
            drawArc(
                color = c,
                startAngle = -55f,
                sweepAngle = 285f,
                useCenter = false,
                topLeft = Offset(u * (0.5f - r), u * (0.5f - r)),
                size = Size(u * 2 * r, u * 2 * r),
                style = stroke,
            )
            path(filled = true) {
                moveTo(u * 0.72f, u * 0.10f)
                lineTo(u * 0.86f, u * 0.30f)
                lineTo(u * 0.62f, u * 0.28f)
                close()
            }
        }
        DvGlyph.Plus -> {
            line(0.5f, 0.24f, 0.5f, 0.76f)
            line(0.24f, 0.5f, 0.76f, 0.5f)
        }
        DvGlyph.Heart, DvGlyph.HeartFilled -> path(filled = glyph == DvGlyph.HeartFilled) {
            moveTo(u * 0.50f, u * 0.79f)
            cubicTo(u * 0.13f, u * 0.55f, u * 0.16f, u * 0.22f, u * 0.50f, u * 0.33f)
            cubicTo(u * 0.84f, u * 0.22f, u * 0.87f, u * 0.55f, u * 0.50f, u * 0.79f)
            close()
        }
        DvGlyph.CheckCircle -> {
            drawCircle(c, u * 0.34f, center, style = stroke)
            path {
                moveTo(u * 0.33f, u * 0.51f)
                lineTo(u * 0.45f, u * 0.63f)
                lineTo(u * 0.68f, u * 0.38f)
            }
        }
        DvGlyph.Restart -> {
            val r = 0.30f
            drawArc(
                color = c,
                startAngle = -150f,
                sweepAngle = 265f,
                useCenter = false,
                topLeft = Offset(u * (0.5f - r), u * (0.5f - r)),
                size = Size(u * 2 * r, u * 2 * r),
                style = stroke,
            )
            line(0.50f, 0.50f, 0.50f, 0.30f)
            line(0.50f, 0.50f, 0.66f, 0.57f)
            path(filled = true) {
                moveTo(u * 0.79f, u * 0.13f)
                lineTo(u * 0.82f, u * 0.36f)
                lineTo(u * 0.60f, u * 0.29f)
                close()
            }
        }
        DvGlyph.Audio -> {
            val bar = u * 0.085f
            listOf(0.30f, 0.56f, 0.38f, 0.62f).forEachIndexed { i, h ->
                val x = u * (0.20f + i * 0.20f)
                drawRoundRect(
                    color = c,
                    topLeft = Offset(x - bar / 2f, u * (0.5f - h / 2f)),
                    size = Size(bar, u * h),
                    cornerRadius = CornerRadius(bar / 2f),
                )
            }
        }
        DvGlyph.Subtitle -> {
            rect(0.12f, 0.24f, 0.76f, 0.50f, 0.09f)
            line(0.27f, 0.45f, 0.73f, 0.45f)
            line(0.27f, 0.58f, 0.58f, 0.58f)
        }
        DvGlyph.Trakt -> {
            drawCircle(c, u * 0.34f, center, style = stroke)
            line(0.35f, 0.36f, 0.65f, 0.36f)
            line(0.50f, 0.36f, 0.50f, 0.68f)
        }
        DvGlyph.Grid -> {
            rect(0.16f, 0.16f, 0.30f, 0.30f, 0.07f)
            rect(0.54f, 0.16f, 0.30f, 0.30f, 0.07f)
            rect(0.16f, 0.54f, 0.30f, 0.30f, 0.07f)
            rect(0.54f, 0.54f, 0.30f, 0.30f, 0.07f)
        }
        DvGlyph.ListRows -> for (i in 0 until 3) {
            val y = 0.26f + i * 0.24f
            drawCircle(c, u * 0.05f, Offset(u * 0.22f, u * y))
            line(0.38f, y, 0.80f, y, stroke.width * 0.9f)
        }
        DvGlyph.Filter -> path {
            moveTo(u * 0.18f, u * 0.26f)
            lineTo(u * 0.82f, u * 0.26f)
            lineTo(u * 0.58f, u * 0.54f)
            lineTo(u * 0.58f, u * 0.76f)
            lineTo(u * 0.42f, u * 0.68f)
            lineTo(u * 0.42f, u * 0.54f)
            close()
        }
        DvGlyph.Sort -> {
            line(0.32f, 0.74f, 0.32f, 0.28f)
            path { moveTo(u * 0.20f, u * 0.40f); lineTo(u * 0.32f, u * 0.26f); lineTo(u * 0.44f, u * 0.40f) }
            line(0.68f, 0.26f, 0.68f, 0.72f)
            path { moveTo(u * 0.56f, u * 0.60f); lineTo(u * 0.68f, u * 0.74f); lineTo(u * 0.80f, u * 0.60f) }
        }
        DvGlyph.Play -> path(filled = true) {
            moveTo(u * 0.34f, u * 0.22f)
            lineTo(u * 0.78f, u * 0.50f)
            lineTo(u * 0.34f, u * 0.78f)
            close()
        }
        DvGlyph.Folder -> path {
            moveTo(u * 0.14f, u * 0.30f)
            lineTo(u * 0.40f, u * 0.30f)
            lineTo(u * 0.46f, u * 0.38f)
            lineTo(u * 0.86f, u * 0.38f)
            lineTo(u * 0.86f, u * 0.74f)
            lineTo(u * 0.14f, u * 0.74f)
            close()
        }
        DvGlyph.Star -> {
            val outer = 0.34f
            val inner = 0.145f
            val pts = (0 until 10).map { i ->
                val r = if (i % 2 == 0) outer else inner
                val a = Math.toRadians((-90 + i * 36).toDouble())
                Offset(
                    u * (0.5f + r * Math.cos(a).toFloat()),
                    u * (0.5f + r * Math.sin(a).toFloat()),
                )
            }
            drawPath(
                Path().apply {
                    moveTo(pts[0].x, pts[0].y)
                    pts.drop(1).forEach { lineTo(it.x, it.y) }
                    close()
                },
                c,
            )
        }
    }
}
