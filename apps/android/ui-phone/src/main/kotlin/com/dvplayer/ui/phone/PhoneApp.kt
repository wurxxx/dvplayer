package com.dvplayer.ui.phone

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.dvplayer.core.Native
import com.dvplayer.design.DvColors
import com.dvplayer.design.DvTheme

/** A2 骨架页：只验证两个 APK 能起、native 能加载。 */
@Composable
fun PhoneApp() {
    DvTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = DvColors.Background) {
            Column(
                modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 48.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = "DVPlayer",
                    style = MaterialTheme.typography.headlineLarge,
                    color = DvColors.Text,
                )
                Text(
                    text = "手机壳 · M2 骨架",
                    style = MaterialTheme.typography.bodyLarge,
                    color = DvColors.Subtle,
                )
                Text(
                    text = nativeVersion(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = DvColors.Muted,
                )
            }
        }
    }
}

private fun nativeVersion(): String = runCatching { "共享核心 ${Native.version()}" }
    .getOrElse { "共享核心未加载：${it.message}" }
