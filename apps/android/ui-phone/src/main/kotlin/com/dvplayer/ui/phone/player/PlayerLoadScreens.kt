package com.dvplayer.ui.phone.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val titleColor = Color(0xFFF5F5F8)
private val bodyColor = Color(0xB3FFFFFF)
private val accentColor = Color(0xFFFFB020)

/** 真实条目加载中。 */
@Composable
fun PlayerLoadingScreen(text: String = "正在连接源…") {
    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Color(0x99FFFFFF), fontSize = 13.sp)
    }
}

/**
 * 打开失败。
 *
 * 播放页是壳层最深处出错的地方，这里必须把**原始错误**露出来（源没连上、
 * 路径过期、解码器不支持），否则只能去翻 logcat。
 */
@Composable
fun PlayerErrorScreen(message: String, onBack: () -> Unit) {
    Box(
        modifier = Modifier.fillMaxSize().background(Color(0xFF141419)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "无法打开播放页",
                color = titleColor,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(text = message, color = bodyColor, fontSize = 12.sp, lineHeight = 18.sp)
            Spacer(Modifier.height(6.dp))
            Text(
                text = "返回",
                color = accentColor,
                fontSize = 13.sp,
                modifier = Modifier
                    .clickable(onClick = onBack)
                    .padding(vertical = 8.dp),
            )
        }
    }
}
