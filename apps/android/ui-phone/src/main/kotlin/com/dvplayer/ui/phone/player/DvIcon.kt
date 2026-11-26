package com.dvplayer.ui.phone.player

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
 * 播放页的线性图标。
 *
 * 不引 `material-icons-extended`：播放页要的图标（快退 / 快进 / 锁 / 音轨 / 字幕）
 * 大半不在 core 图标集里，而 extended 在 Compose 1.8 之后停更。这里用 Canvas 画，
 * 尺寸、线宽和参考图一致，也不多带几百 KB。
 */
enum class DvIcon {
    Close, Play, Pause, Rewind, Forward, Next, Lock, Volume, Pip,
    Fullscreen, Subtitle, Audio, Speed, Gear, More, Check,
}

@Composable
fun DvIcon(
    icon: DvIcon,
    modifier: Modifier = Modifier,
    tint: Color = Color.White,
    sizeDp: Int = 24,
) {
    Canvas(modifier = modifier.size(sizeDp.dp)) {
        val u = this.size.minDimension
        val stroke = Stroke(
            width = u * 0.07f,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        )
        when (icon) {
            DvIcon.Close -> {
                line(tint, u, 0.3f, 0.3f, 0.7f, 0.7f, stroke)
                line(tint, u, 0.7f, 0.3f, 0.3f, 0.7f, stroke)
            }
            DvIcon.Play -> fill(tint, u) {
                moveTo(u * 0.32f, u * 0.22f)
                lineTo(u * 0.78f, u * 0.5f)
                lineTo(u * 0.32f, u * 0.78f)
                close()
            }
            DvIcon.Pause -> {
                roundBar(tint, u, 0.30f, 0.20f, 0.115f, 0.60f)
                roundBar(tint, u, 0.585f, 0.20f, 0.115f, 0.60f)
            }
            // 双三角指向左：顶点在左，底边在右。
            DvIcon.Rewind -> {
                fill(tint, u) {
                    moveTo(u * 0.50f, u * 0.26f)
                    lineTo(u * 0.19f, u * 0.5f)
                    lineTo(u * 0.50f, u * 0.74f)
                    close()
                }
                fill(tint, u) {
                    moveTo(u * 0.81f, u * 0.26f)
                    lineTo(u * 0.50f, u * 0.5f)
                    lineTo(u * 0.81f, u * 0.74f)
                    close()
                }
            }
            // 双三角指向右：顶点在右，底边在左。
            DvIcon.Forward -> {
                fill(tint, u) {
                    moveTo(u * 0.19f, u * 0.26f)
                    lineTo(u * 0.50f, u * 0.5f)
                    lineTo(u * 0.19f, u * 0.74f)
                    close()
                }
                fill(tint, u) {
                    moveTo(u * 0.50f, u * 0.26f)
                    lineTo(u * 0.81f, u * 0.5f)
                    lineTo(u * 0.50f, u * 0.74f)
                    close()
                }
            }
            DvIcon.Next -> {
                fill(tint, u) {
                    moveTo(u * 0.24f, u * 0.26f)
                    lineTo(u * 0.62f, u * 0.5f)
                    lineTo(u * 0.24f, u * 0.74f)
                    close()
                }
                line(tint, u, 0.70f, 0.26f, 0.70f, 0.74f, stroke)
            }
            DvIcon.Lock -> {
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(u * 0.28f, u * 0.45f),
                    size = Size(u * 0.44f, u * 0.41f),
                    cornerRadius = CornerRadius(u * 0.07f),
                    style = stroke,
                )
                drawArc(
                    color = tint,
                    startAngle = 180f,
                    sweepAngle = 180f,
                    useCenter = false,
                    topLeft = Offset(u * 0.35f, u * 0.19f),
                    size = Size(u * 0.30f, u * 0.30f),
                    style = stroke,
                )
            }
            DvIcon.Volume -> {
                fill(tint, u) {
                    moveTo(u * 0.16f, u * 0.42f)
                    lineTo(u * 0.34f, u * 0.42f)
                    lineTo(u * 0.50f, u * 0.28f)
                    lineTo(u * 0.50f, u * 0.72f)
                    lineTo(u * 0.34f, u * 0.58f)
                    lineTo(u * 0.16f, u * 0.58f)
                    close()
                }
                drawArc(
                    color = tint,
                    startAngle = -55f,
                    sweepAngle = 110f,
                    useCenter = false,
                    topLeft = Offset(u * 0.50f, u * 0.37f),
                    size = Size(u * 0.20f, u * 0.26f),
                    style = stroke,
                )
                drawArc(
                    color = tint,
                    startAngle = -55f,
                    sweepAngle = 110f,
                    useCenter = false,
                    topLeft = Offset(u * 0.50f, u * 0.28f),
                    size = Size(u * 0.32f, u * 0.44f),
                    style = stroke,
                )
            }
            DvIcon.Pip -> {
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(u * 0.14f, u * 0.24f),
                    size = Size(u * 0.72f, u * 0.50f),
                    cornerRadius = CornerRadius(u * 0.07f),
                    style = stroke,
                )
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(u * 0.54f, u * 0.50f),
                    size = Size(u * 0.25f, u * 0.16f),
                    cornerRadius = CornerRadius(u * 0.03f),
                )
            }
            DvIcon.Fullscreen -> {
                corner(tint, stroke, u, 0.22f, 0.22f, 1f, 1f)
                corner(tint, stroke, u, 0.78f, 0.22f, -1f, 1f)
                corner(tint, stroke, u, 0.78f, 0.78f, -1f, -1f)
                corner(tint, stroke, u, 0.22f, 0.78f, 1f, -1f)
            }
            DvIcon.Subtitle -> {
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(u * 0.14f, u * 0.24f),
                    size = Size(u * 0.72f, u * 0.48f),
                    cornerRadius = CornerRadius(u * 0.08f),
                    style = stroke,
                )
                line(tint, u, 0.28f, 0.46f, 0.72f, 0.46f, stroke)
                line(tint, u, 0.28f, 0.58f, 0.58f, 0.58f, stroke)
            }
            // 音符：符头 + 符干 + 符尾，比同心圆更像「音轨」。
            DvIcon.Audio -> {
                drawCircle(color = tint, center = Offset(u * 0.34f, u * 0.70f), radius = u * 0.105f)
                line(tint, u, 0.445f, 0.70f, 0.445f, 0.26f, stroke)
                val flag = Path().apply {
                    moveTo(u * 0.445f, u * 0.26f)
                    cubicTo(
                        u * 0.60f, u * 0.30f,
                        u * 0.72f, u * 0.36f,
                        u * 0.70f, u * 0.50f,
                    )
                }
                drawPath(flag, tint, style = stroke)
            }
            DvIcon.Speed -> {
                drawCircle(color = tint, radius = u * 0.30f, style = stroke)
                line(tint, u, 0.5f, 0.5f, 0.5f, 0.30f, stroke)
                line(tint, u, 0.5f, 0.5f, 0.66f, 0.56f, stroke)
            }
            DvIcon.Gear -> {
                // 外圈 + 内孔 + 8 个短齿；只画辐条会变成「太阳」。
                drawCircle(color = tint, radius = u * 0.26f, style = stroke)
                drawCircle(color = tint, radius = u * 0.085f)
                for (i in 0 until 8) {
                    val a = Math.toRadians(i * 45.0)
                    val c = Math.cos(a).toFloat()
                    val s = Math.sin(a).toFloat()
                    drawLine(
                        color = tint,
                        start = Offset(u * (0.5f + c * 0.25f), u * (0.5f + s * 0.25f)),
                        end = Offset(u * (0.5f + c * 0.36f), u * (0.5f + s * 0.36f)),
                        strokeWidth = stroke.width * 1.5f,
                        cap = StrokeCap.Round,
                    )
                }
            }
            DvIcon.More -> {
                for (x in listOf(0.30f, 0.50f, 0.70f)) {
                    drawCircle(color = tint, radius = u * 0.055f, center = Offset(u * x, u * 0.5f))
                }
            }
            DvIcon.Check -> {
                val path = Path().apply {
                    moveTo(u * 0.26f, u * 0.52f)
                    lineTo(u * 0.43f, u * 0.68f)
                    lineTo(u * 0.74f, u * 0.34f)
                }
                drawPath(path, tint, style = stroke)
            }
        }
    }
}

private fun DrawScope.line(
    color: Color,
    u: Float,
    x1: Float,
    y1: Float,
    x2: Float,
    y2: Float,
    style: Stroke,
) = drawLine(
    color = color,
    start = Offset(u * x1, u * y1),
    end = Offset(u * x2, u * y2),
    strokeWidth = style.width,
    cap = StrokeCap.Round,
)

private fun DrawScope.fill(color: Color, u: Float, build: Path.() -> Unit) {
    val path = Path().apply(build)
    drawPath(path, color)
}

private fun DrawScope.roundBar(
    color: Color,
    u: Float,
    x: Float,
    y: Float,
    w: Float,
    h: Float,
) = drawRoundRect(
    color = color,
    topLeft = Offset(u * x, u * y),
    size = Size(u * w, u * h),
    cornerRadius = CornerRadius(u * 0.035f),
)

/** 全屏图标的四角：从角点向两个方向各画一段。 */
private fun DrawScope.corner(
    color: Color,
    stroke: Stroke,
    u: Float,
    x: Float,
    y: Float,
    dx: Float,
    dy: Float,
) {
    val arm = u * 0.17f
    drawLine(
        color = color,
        start = Offset(u * x, u * y),
        end = Offset(u * x + arm * dx, u * y),
        strokeWidth = stroke.width,
        cap = StrokeCap.Round,
    )
    drawLine(
        color = color,
        start = Offset(u * x, u * y),
        end = Offset(u * x, u * y + arm * dy),
        strokeWidth = stroke.width,
        cap = StrokeCap.Round,
    )
}
