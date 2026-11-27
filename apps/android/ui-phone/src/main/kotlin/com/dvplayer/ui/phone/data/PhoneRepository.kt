package com.dvplayer.ui.phone.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import com.dvplayer.core.CoreException
import com.dvplayer.core.Genre
import com.dvplayer.core.ImageSource
import com.dvplayer.core.ListQuery
import com.dvplayer.core.MediaDetail
import com.dvplayer.core.MediaHub
import com.dvplayer.core.MediaInfo
import com.dvplayer.core.MediaItem
import com.dvplayer.core.MediaLibrary
import com.dvplayer.core.Page
import com.dvplayer.core.Person
import com.dvplayer.core.PlayRecord
import com.dvplayer.core.SearchResult
import com.dvplayer.core.SourceConfig
import com.dvplayer.core.SourceConnection
import com.dvplayer.core.config.SourceStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * 手机端唯一的数据入口。
 *
 * 一个 `MediaHub` 活到进程结束：每次进页面重连会重新登录所有源，Emby 上一次就是
 * 几百毫秒，切个 tab 就卡一下。源配置走 [SourceStore]（播放页读的是同一份），
 * 连接结果留在 [connections] 里，失败的源也保留，让源列表能显示「失败 + 重试」。
 *
 * 所有网络 / 解码方法都是 suspend，内部切到 IO。
 */
class PhoneRepository(context: Context) {

    private val appContext = context.applicationContext
    private val store = SourceStore(appContext)

    /** 配置里有哪些源（含连不上的）。 */
    var configs by mutableStateOf<List<SourceConfig>>(emptyList())
        private set

    /** 每个源的连接结果；key 是 sourceId。 */
    val connections = mutableStateMapOf<String, SourceConnection>()

    /** 连上的源返回的库（按 sourceId 分组前）。 */
    var libraries by mutableStateOf<List<MediaLibrary>>(emptyList())
        private set

    /** 每个库的条目总数；拿不到就不放这个 key（界面显示 —）。 */
    var counts by mutableStateOf<Map<String, Long>>(emptyMap())
        private set

    var connecting by mutableStateOf(false)
        private set

    /** 正在单独重连的源；卡片据此显示「重连中」。 */
    var reconnecting by mutableStateOf<Set<String>>(emptySet())
        private set

    /** 第一次连接流程走完（无论成功失败）。 */
    var ready by mutableStateOf(false)
        private set

    var lastError by mutableStateOf<String?>(null)
        private set

    private var hubHandle: MediaHub? = null
    private val hubLock = Mutex()

    private val images = LruCache<String, Bitmap>(32 * 1024 * 1024)
    private val imageLock = Mutex()

    // ---------------------------------------------------------------- 连接

    suspend fun connect() {
        val loaded = withContext(Dispatchers.IO) { store.load() }
        configs = loaded.sortedBy { it.name }
        if (loaded.isEmpty()) {
            ready = true
            return
        }
        connecting = true
        lastError = null
        try {
            val h = ensureHub() ?: run {
                lastError = "核心未加载"
                return
            }
            val padded = loaded.map {
                if (it.dataDir.isBlank()) it.copy(dataDir = appContext.filesDir.absolutePath) else it
            }
            withContext(Dispatchers.IO) {
                val result = runCatching { h.addMany(padded) }
                val list = result.getOrElse { err ->
                    lastError = err.message ?: err.toString()
                    emptyList()
                }
                connections.clear()
                list.forEach { connections[it.id] = it }
                // 配置里有、核心没回的（配置解析失败之类）也要占位。
                padded.filter { cfg -> list.none { it.id == cfg.id } }.forEach { cfg ->
                    connections[cfg.id] = SourceConnection(
                        id = cfg.id,
                        name = cfg.name,
                        kind = cfg.kind,
                        ok = false,
                        error = "未返回连接结果",
                    )
                }
                libraries = runCatching { h.libraries() }.getOrDefault(emptyList())
                counts = loadCounts(h, libraries, connections)
            }
        } finally {
            connecting = false
            ready = true
        }
    }

    /** 重新连单个源（失败卡片点一下重试）。 */
    suspend fun reconnect(sourceId: String) {
        val cfg = configs.firstOrNull { it.id == sourceId } ?: return
        val h = ensureHub() ?: return
        reconnecting = reconnecting + sourceId
        try {
            withContext(Dispatchers.IO) {
                val result = runCatching { h.add(cfg.copy(dataDir = cfg.dataDir.ifBlank { appContext.filesDir.absolutePath })) }
                connections[sourceId] = result.fold(
                    onSuccess = { SourceConnection(sourceId, cfg.name, cfg.kind, ok = true) },
                    onFailure = { err ->
                        // 界面只显示一句人话，原始错误留给 logcat 排查。
                        Log.w("DvSource", "重连 ${cfg.name} 失败", err)
                        SourceConnection(sourceId, cfg.name, cfg.kind, ok = false, error = err.message)
                    },
                )
                libraries = runCatching { h.libraries() }.getOrDefault(emptyList())
                counts = loadCounts(h, libraries, connections)
            }
        } finally {
            reconnecting = reconnecting - sourceId
        }
    }

    private fun loadCounts(
        h: MediaHub,
        libs: List<MediaLibrary>,
        conns: Map<String, SourceConnection>,
    ): Map<String, Long> {
        val map = mutableMapOf<String, Long>()
        for (lib in libs) {
            if (conns[lib.sourceId]?.ok != true) continue
            runCatching { h.items(lib.id, page = 1, pageSize = 1).total }
                .onSuccess { map[lib.id] = it }
        }
        return map
    }

    private suspend fun ensureHub(): MediaHub? = hubLock.withLock {
        hubHandle?.let { return it }
        withContext(Dispatchers.IO) { MediaHub.open() }?.also { hubHandle = it }
    }

    // ---------------------------------------------------------------- 配置

    fun addSource(config: SourceConfig) {
        store.upsert(config)
        configs = store.load().sortedBy { it.name }
    }

    fun removeSource(id: String) {
        store.remove(id)
        configs = store.load().sortedBy { it.name }
        connections.remove(id)
        libraries = libraries.filterNot { it.sourceId == id }
        counts = counts.filterKeys { key -> libraries.any { it.id == key } }
    }

    fun libraryOf(sourceId: String): List<MediaLibrary> =
        libraries.filter { it.sourceId == sourceId }

    fun totalOf(sourceId: String): Long =
        libraryOf(sourceId).sumOf { counts[it.id] ?: 0L }

    fun connectedCount(): Int = connections.count { it.value.ok }

    // ---------------------------------------------------------------- 浏览

    suspend fun items(
        libraryId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.items(libraryId, page, pageSize, query)
    }

    suspend fun children(
        parentId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.children(parentId, page, pageSize, query)
    }

    suspend fun detail(itemId: String): MediaDetail = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.detail(itemId)
    }

    suspend fun genres(scopeId: String): List<Genre> = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        runCatching { h.genres(scopeId) }.getOrDefault(emptyList())
    }

    suspend fun people(itemId: String): List<Person> = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: return@withContext emptyList()
        runCatching { h.people(itemId) }
            .onFailure { Log.w("DvRepo", "people($itemId) 失败：${it.message}") }
            .getOrDefault(emptyList())
    }

    suspend fun mediaInfo(itemId: String): MediaInfo? = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: return@withContext null
        runCatching { h.mediaInfo(itemId) }.getOrNull()
    }

    suspend fun search(query: String): SearchResult = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.search(query)
    }

    suspend fun records(): List<PlayRecord> = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        runCatching { h.records() }.getOrDefault(emptyList())
    }

    suspend fun favorites(page: Int = 1, pageSize: Int = 60): Page<MediaItem> =
        withContext(Dispatchers.IO) {
            val h = ensureHub() ?: throw CoreException("核心未加载")
            h.favorites(page, pageSize)
        }

    suspend fun setFavorite(itemId: String, favorite: Boolean) = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.setFavorite(itemId, favorite)
    }

    suspend fun setWatched(itemId: String, watched: Boolean) = withContext(Dispatchers.IO) {
        val h = ensureHub() ?: throw CoreException("核心未加载")
        h.setWatched(itemId, watched)
    }

    // ---------------------------------------------------------------- 图片

    /**
     * 图片按 URL 缓存：Emby 的海报 URL 里带 token，同一个条目的 URL 是稳定的，
     * 所以 URL 当 key 比自己拼 `sourceId:itemId` 更省事。
     */
    suspend fun bitmap(path: String?): Bitmap? {
        val trimmed = path?.takeIf { it.isNotBlank() } ?: return null
        images.get(trimmed)?.let { return it }
        return imageLock.withLock {
            images.get(trimmed)?.let { return@withLock it }
            withContext(Dispatchers.IO) {
                runCatching {
                    val src = resolveImage(trimmed) ?: return@runCatching null
                    val bytes = fetch(src) ?: return@runCatching null
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.also { images.put(trimmed, it) }
                }.getOrNull()
            }
        }
    }

    private fun resolveImage(path: String): ImageSource? {
        val h = hubHandle ?: return null
        return runCatching { h.imageSource(path) }.getOrNull()
    }

    private fun fetch(src: ImageSource): ByteArray? {
        // 本地源给的是 file://，Emby / FnOS 给的是带鉴权头的 http(s)。
        if (src.url.startsWith("file:")) {
            return runCatching { File(URI(src.url)).readBytes() }.getOrNull()
        }
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(src.url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8_000
                readTimeout = 12_000
                instanceFollowRedirects = true
                src.headers.forEach { addRequestProperty(it.name, it.value) }
            }
            if (conn.responseCode !in 200..299) null
            else conn.inputStream.use { it.readBytes() }
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    fun clearImages() = images.evictAll()
}

/**
 * 进程里唯一那个 [PhoneRepository]。
 *
 * 播放页是另一个 Activity，但剧照还是要走这里的位图缓存（`imageSource` 的鉴权
 * 只有核心知道怎么拼）；由 [com.dvplayer.ui.phone.PhoneApp] 在启动时填进来。
 */
object PhoneRepoHolder {
    @Volatile
    var repo: PhoneRepository? = null
}
