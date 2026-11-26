package com.dvplayer.core.config

import android.content.Context
import com.dvplayer.core.SourceConfig
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * 源配置的本地存储。
 *
 * 只存「连哪、用哪个适配器、用户名」这类非机密字段；SMB / WebDAV 的密码在
 * [com.dvplayer.core.credential.CredentialStore] 里用 Keystore 加密单独存。
 *
 * 现在是 SharedPreferences + JSON：源列表很短，改一个源要整表重写也没关系。
 * 以后设置页、浏览页、播放页都从这里读，保证只有一份配置。
 *
 * **线程**：读写都很轻，允许主线程；但登录 / 浏览仍然必须放工作线程。
 */
class SourceStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    private val json = jsonFormat

    /** 已保存的源；坏数据跳过，不让一条脏记录毁掉整个列表。 */
    fun load(): List<SourceConfig> {
        val raw = prefs.getString(KEY_SOURCES, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(SourceConfig.serializer()), raw)
        }.getOrDefault(emptyList())
    }

    fun save(sources: List<SourceConfig>) {
        prefs.edit()
            .putString(KEY_SOURCES, json.encodeToString(ListSerializer(SourceConfig.serializer()), sources))
            .apply()
    }

    /** 同 id 覆盖，否则追加。 */
    fun upsert(config: SourceConfig) {
        val list = load().toMutableList()
        val index = list.indexOfFirst { it.id == config.id }
        if (index >= 0) list[index] = config else list.add(config)
        save(list)
    }

    fun remove(id: String) {
        save(load().filterNot { it.id == id })
    }

    fun clear() {
        prefs.edit().remove(KEY_SOURCES).apply()
    }

    companion object {
        private const val PREF_NAME = "dv_sources"
        private const val KEY_SOURCES = "sources_json"

        private val jsonFormat = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            explicitNulls = false
        }

        /**
         * 解析命令行 / 剪贴板里的 `SourceConfig` JSON。
         *
         * 放在这里而不是让调用方各自建 `Json`：字段默认值和 `dataDir` 的补全规则
         * 必须和落盘的那份一致。
         */
        fun parse(raw: String): SourceConfig? =
            runCatching { jsonFormat.decodeFromString(SourceConfig.serializer(), raw) }.getOrNull()
    }
}
