package com.dvplayer.core.credential

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 一个源的凭据。目前只有 SMB / WebDAV 用。 */
data class Credential(val user: String, val password: String)

/**
 * SMB / WebDAV 凭据的本地存储（A9）。
 *
 * 密码不能明文进 SharedPreferences：`adb backup`、root、云备份都会把它捞出去。
 * 这里用 Android Keystore 里的 AES-256-GCM 密钥加密后再存；密钥不出 TEE /
 * StrongBox，应用卸载时一起销毁。
 *
 * scope 用「协议 + 主机 + 端口」（`smb://10.0.0.134:445`、
 * `https://dav.example.com:443`），换共享不用重存。
 *
 * 解密失败（系统换了密钥、备份恢复到新机）时直接删掉那条记录，让用户重输，
 * 不抛异常打断启动。
 */
class CredentialStore(context: Context) {

    private val tag = "DvCred"
    private val prefs =
        context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    fun save(scope: String, credential: Credential): Boolean {
        if (credential.user.isEmpty() && credential.password.isEmpty()) return false
        return runCatching {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            val plain = credential.user.toByteArray(Charsets.UTF_8) +
                SEPARATOR +
                credential.password.toByteArray(Charsets.UTF_8)
            val encrypted = cipher.doFinal(plain)
            prefs.edit().putString(key(scope), pack(cipher.iv, encrypted)).apply()
            Log.i(tag, "已保存 ${redactScope(scope)} 的凭据")
            true
        }.getOrElse {
            Log.w(tag, "保存凭据失败：${it.message}")
            false
        }
    }

    fun load(scope: String): Credential? {
        val stored = prefs.getString(key(scope), null) ?: return null
        return runCatching {
            val (iv, data) = unpack(stored) ?: error("格式错误")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            val plain = cipher.doFinal(data)
            parse(plain)
        }.getOrElse {
            Log.w(tag, "凭据解密失败，已清除 ${redactScope(scope)}：${it.message}")
            remove(scope)
            null
        }
    }

    fun remove(scope: String) {
        prefs.edit().remove(key(scope)).apply()
    }

    fun scopes(): Set<String> =
        prefs.all.keys.filter { it.startsWith(PREFIX) }.map { it.removePrefix(PREFIX) }.toSet()

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun parse(plain: ByteArray): Credential {
        val at = plain.indexOf(SEPARATOR)
        if (at < 0) return Credential(String(plain, Charsets.UTF_8), "")
        return Credential(
            String(plain, 0, at, Charsets.UTF_8),
            String(plain, at + 1, plain.size - at - 1, Charsets.UTF_8),
        )
    }

    private fun key(scope: String) = PREFIX + scope

    /** `iv:密文`，两段都用无填充 Base64。 */
    private fun pack(iv: ByteArray, data: ByteArray): String =
        Base64.getEncoder().encodeToString(iv) + ":" +
            Base64.getEncoder().encodeToString(data)

    private fun unpack(stored: String): Pair<ByteArray, ByteArray>? {
        val at = stored.indexOf(':')
        if (at <= 0) return null
        val decoder = Base64.getDecoder()
        return runCatching {
            decoder.decode(stored.substring(0, at)) to decoder.decode(stored.substring(at + 1))
        }.getOrNull()
    }

    companion object {
        private const val PREF_NAME = "dvplayer_credentials"
        private const val PREFIX = "cred:"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "dvplayer_credentials_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
        private const val SEPARATOR = '\n'.code.toByte()

        /** 日志里只留协议和主机，绝不打用户名 / 密码。 */
        fun redactScope(scope: String): String =
            scope.replace(Regex("""//[^/@]+@"""), "//")
    }
}
