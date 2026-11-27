package com.dvplayer.ui.phone.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowCompat
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.platform.LocalView
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.SourceConfig
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.ui.phone.ui.DvPill
import java.util.UUID

private val SourceKinds = listOf(
    "emby" to "Emby",
    "jellyfin" to "Jellyfin",
    "fnos" to "FnOS",
    "local" to "本地目录",
)

/**
 * 添加媒体源。
 *
 * 密码还是走 [SourceConfig.password]（明文进 SharedPreferences）——这是现有契约，
 * 核心的 emby 适配器从配置里读。SMB / WebDAV 的凭据才走 Keystore 加密的
 * `CredentialStore`。改这条要动 Rust 侧，不在这一批。
 */
@Composable
fun AddSourceDialog(
    onDismiss: () -> Unit,
    onConfirm: (SourceConfig) -> Unit,
) {
    val p = DvTheme.palette
    var kind by remember { mutableStateOf("emby") }
    var name by remember { mutableStateOf("") }
    var base by remember { mutableStateOf("") }
    var userName by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }

    val isLocal = kind == "local"
    val addressError = if (isLocal) null else checkAddress(base)
    val canSubmit = name.isNotBlank() && base.isNotBlank() && addressError == null

    AlertDialog(
        onDismissRequest = onDismiss,
        // 弹窗也是全屏应用的一部分：别让状态栏和导航栏在打开它的时候冒出来。
        properties = DialogProperties(decorFitsSystemWindows = false),
        // 全屏弹窗不吃系统的 resize，键盘弹出来会盖住「添加」；自己让出键盘高度。
        modifier = Modifier.imePadding(),
        containerColor = p.surface,
        title = { Text("添加媒体源", style = DvType.SectionTitle, color = p.text) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                FullscreenDialog()
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    SourceKinds.take(2).forEach { (value, label) ->
                        DvPill(label, selected = kind == value, onClick = { kind = value })
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    SourceKinds.drop(2).forEach { (value, label) ->
                        DvPill(label, selected = kind == value, onClick = { kind = value })
                    }
                }

                Field("名称", name, { name = it }, "客厅 Emby")
                Field(
                    if (isLocal) "目录" else "地址",
                    base,
                    { base = it },
                    if (isLocal) "/sdcard/Movies" else "http://10.0.0.134:8096",
                )
                if (!isLocal) {
                    Field("用户名", userName, { userName = it }, "可留空")
                    Field("密码", pass, { pass = it }, "", isSecret = true)
                }

                Text(
                    addressError ?: when (kind) {
                        "local" -> "本地目录直接读文件系统，不需要账号。"
                        "fnos" -> "FnOS 影视接口一般走 http://主机:8005（也有 15666）。"
                        else -> "地址填服务器根地址，不要带 /web 后缀。"
                    },
                    style = DvType.Micro,
                    color = if (addressError != null) p.danger else p.faint,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onConfirm(
                        SourceConfig(
                            id = "s-" + UUID.randomUUID().toString().take(8),
                            name = name.trim(),
                            kind = kind,
                            base = base.trim(),
                            username = userName.trim(),
                            password = pass,
                        ),
                    )
                },
                enabled = canSubmit,
            ) {
                Text("添加", color = if (canSubmit) p.accent else p.faint)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = p.muted)
            }
        },
    )
}

/**
 * 检查用户填的服务器地址。
 *
 * 只拦「一定连不上」的写法：没有 scheme、IP 段越界、端口越界。
 * 不做 DNS / 连通性检查——那是点「添加」之后的事。
 */
private fun checkAddress(raw: String): String? {
    val text = raw.trim()
    if (text.isEmpty()) return null
    val hasScheme = text.startsWith("http://", ignoreCase = true) ||
        text.startsWith("https://", ignoreCase = true)
    if (!hasScheme) return "地址要以 http:// 或 https:// 开头"

    val authority = text.substringAfter("://").substringBefore('/').substringBefore('?')
    if (authority.isBlank()) return "地址里没有主机名"

    val hostPart = authority.substringBeforeLast(':', authority)
    val portPart = authority.substringAfterLast(':', "")

    // 四段数字按 IP 校验，其余当主机名放行。
    val ipLike = Regex("^\\d+(\\.\\d+){3}$")
    if (ipLike.matches(hostPart)) {
        val octets = hostPart.split('.').map { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it == null || it !in 0..255 }) {
            return "IP 地址不合法，检查是不是少写了一段"
        }
    }
    if (portPart.isNotEmpty()) {
        val port = portPart.toIntOrNull() ?: return "端口必须是数字"
        if (port !in 1..65535) return "端口超出 1–65535"
    }
    return null
}

/**
 * 弹窗有自己的 window，Activity 里隐藏系统栏管不到它。
 *
 * 不处理的话，打开「添加媒体源」那一下状态栏和导航栏会冒出来，全屏就断了。
 */
@Composable
private fun FullscreenDialog() {
    val view = LocalView.current
    SideEffect {
        val window = (view.parent as? DialogWindowProvider)?.window ?: return@SideEffect
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, view).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }
}

@Composable
private fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    isSecret: Boolean = false,
) {
    val p = DvTheme.palette
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        singleLine = true,
        label = { Text(label, style = DvType.Micro, color = p.faint) },
        placeholder = { Text(placeholder, style = DvType.Caption, color = p.faint) },
        textStyle = DvType.Caption.copy(color = p.text),
        visualTransformation = if (isSecret) PasswordVisualTransformation() else VisualTransformation.None,
        shape = RoundedCornerShape(9.dp),
        modifier = Modifier.fillMaxWidth(),
    )
}
