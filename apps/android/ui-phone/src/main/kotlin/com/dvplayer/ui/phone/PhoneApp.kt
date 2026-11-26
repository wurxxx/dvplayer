package com.dvplayer.ui.phone

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.dvplayer.core.Capabilities
import com.dvplayer.core.Native
import com.dvplayer.design.DvColors
import com.dvplayer.design.DvTheme

/** A1 骨架页：native 自检 + 设备能力快照（A1 的静态部分）。 */
@Composable
fun PhoneApp() {
    val context = LocalContext.current
    // 采集一次就够，别每次重组都重新枚举 MediaCodecList。
    val profile = remember { Capabilities.collect(context) }

    DvTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = DvColors.Background) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 32.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    text = "DVPlayer",
                    style = MaterialTheme.typography.headlineLarge,
                    color = DvColors.Text,
                )
                Text(
                    text = nativeVersion(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = DvColors.Muted,
                )

                Text(
                    text = "设备能力",
                    style = MaterialTheme.typography.titleMedium,
                    color = DvColors.Text,
                )
                profile.summary.forEach { line ->
                    Text(
                        text = line,
                        style = MaterialTheme.typography.bodyMedium,
                        color = DvColors.Subtle,
                    )
                }

                Text(
                    text = profile.json,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = DvColors.Muted,
                )
            }
        }
    }
}

private fun nativeVersion(): String = runCatching { "共享核心 ${Native.version()}" }
    .getOrElse { "共享核心未加载：${it.message}" }
