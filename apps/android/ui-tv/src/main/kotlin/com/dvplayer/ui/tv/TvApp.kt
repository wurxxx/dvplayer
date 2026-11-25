package com.dvplayer.ui.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dvplayer.core.Native
import com.dvplayer.design.DvColors

/** A2 骨架页：验证 TV APK 能起、leanback 桌面能看到、native 能加载。 */
@Composable
fun TvApp() {
    MaterialTheme {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(DvColors.Background)
                .padding(48.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = "DVPlayer TV",
                color = DvColors.Text,
                fontSize = 40.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "TV 壳 · M2 骨架",
                color = DvColors.Subtle,
                fontSize = 18.sp,
            )
            Text(
                text = nativeVersion(),
                color = DvColors.Muted,
                fontSize = 16.sp,
            )
        }
    }
}

private fun nativeVersion(): String = runCatching { "共享核心 ${Native.version()}" }
    .getOrElse { "共享核心未加载：${it.message}" }
