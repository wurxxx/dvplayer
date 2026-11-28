package com.dvplayer.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.Closeable

/** 核心返回 `{"ok":false}` 时抛出；[code] 是服务端的错误码（HTTP 状态之类）。 */
class CoreException(message: String, val code: Long? = null) : Exception(message)

/**
 * 共享核心的 Kotlin 门面。
 *
 * **线程**：所有方法都是阻塞的（核心内部用同步 HTTP），必须在工作线程调用；
 * [androidx.annotation.WorkerThread] 的语义，但 core 不引 androidx，靠注释约定。
 * 同一个 [MediaHub] 可以被多个线程并发调用（核心内部有锁），但会串行执行。
 */
internal object CoreJson {
    @OptIn(ExperimentalSerializationApi::class)
    val format = Json {
        // 桌面端 / 服务端加字段时 Android 老版本不能崩。
        ignoreUnknownKeys = true
        // 让 `null` 的默认值不参与序列化（查询参数、可选字段）。
        explicitNulls = false
        // SourceConfig 的默认值（空用户名、空密码…）必须真的发出去。
        encodeDefaults = true
    }
}

private inline fun <reified T> decodeEnvelope(text: String): T {
    val envelope = try {
        CoreJson.format.decodeFromString<CoreEnvelope<T>>(text)
    } catch (err: SerializationException) {
        throw CoreException("核心响应解析失败：${err.message}（原文：${text.take(200)}）")
    }
    if (!envelope.ok) throw CoreException(envelope.error ?: "核心返回失败", envelope.code)
    return envelope.data ?: throw CoreException("核心响应缺少 data")
}

private inline fun <reified T> decodeEnvelopeOrNull(text: String): T? = try {
    decodeEnvelope<T>(text)
} catch (_: CoreException) {
    null
}

/** 只要 ok，不看 data（`report_progress` 这类）。 */
private fun expectOk(text: String) {
    val envelope = try {
        CoreJson.format.decodeFromString<CoreEnvelope<Unit>>(text)
    } catch (err: SerializationException) {
        throw CoreException("核心响应解析失败：${err.message}（原文：${text.take(200)}）")
    }
    if (!envelope.ok) throw CoreException(envelope.error ?: "核心返回失败", envelope.code)
}

/** 不依赖 hub 的几个入口：版本、适配器类型、DV 探测。 */
object DvCore {
    /** 核心库版本；没打包进来时是 `unavailable（原因）`（不抛）。 */
    val version: String by lazy {
        runCatching { decodeEnvelope<String>(Native.coreVersion()) }
            .getOrElse { err ->
                "unavailable（${err.javaClass.simpleName}：${err.message}）"
            }
    }

    /** 支持哪些适配器：`fnos` / `emby` / `jellyfin` / `local`。 */
    fun sourceKinds(): List<String> = decodeEnvelope(Native.sourceKinds())

    /**
     * 判定 DV P7 是 FEL 还是 MEL。
     *
     * 只读码流前缀，找不到 RPU 就返回 null（这不是错误，P8 / SDR 片源本来就没有）。
     */
    fun probeDovi(
        url: String,
        headers: List<HttpHeader> = emptyList(),
        proxy: String = "",
    ): DoviInfo? {
        val headersJson = if (headers.isEmpty()) null
        else CoreJson.format.encodeToString(ListSerializer(HttpHeader.serializer()), headers)
        return decodeEnvelopeOrNull(Native.probeDovi(url, headersJson, proxy.ifEmpty { null }))
    }
}

/**
 * 单源句柄：不经过聚合层，直接问一个服务器。
 *
 * 界面一般用 [MediaHub]；这个留给「添加源」时的试连、以及只配了一个源的场景。
 */
class MediaSourceHandle private constructor(private var handle: Long) : Closeable {

    companion object {
        /** 建不出来（`kind` 不认识 / 配置解析失败）返回 null。 */
        fun open(config: SourceConfig): MediaSourceHandle? {
            val handle = Native.sourceCreate(CoreJson.format.encodeToString(SourceConfig.serializer(), config))
            return if (handle == 0L) null else MediaSourceHandle(handle)
        }
    }

    private fun raw(): Long {
        check(handle != 0L) { "MediaSourceHandle 已关闭" }
        return handle
    }

    /** 登录，返回服务器给的名称与类型。 */
    fun connect(): SourceInfo = decodeEnvelope(Native.connect(raw()))

    fun libraries(): List<MediaLibrary> = decodeEnvelope(Native.libraries(raw()))

    fun items(
        libraryId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = decodeEnvelope(
        Native.items(raw(), libraryId, page, pageSize, query?.let { CoreJson.format.encodeToString(ListQuery.serializer(), it) }),
    )

    fun children(
        parentId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = decodeEnvelope(
        Native.children(raw(), parentId, page, pageSize, query?.let { CoreJson.format.encodeToString(ListQuery.serializer(), it) }),
    )

    fun records(): List<PlayRecord> = decodeEnvelope(Native.records(raw()))

    fun reportProgress(itemId: String, positionSeconds: Long, durationSeconds: Long) =
        expectOk(Native.reportProgress(raw(), itemId, positionSeconds, durationSeconds))

    fun reportStopped(itemId: String, positionSeconds: Long, durationSeconds: Long) =
        expectOk(Native.reportStopped(raw(), itemId, positionSeconds, durationSeconds))

    fun detail(itemId: String): MediaDetail = decodeEnvelope(Native.itemDetail(raw(), itemId))

    fun playSource(itemId: String): PlaySource = decodeEnvelope(Native.playSource(raw(), itemId))

    fun imageSource(path: String): ImageSource = decodeEnvelope(Native.imageSource(raw(), path))

    override fun close() {
        if (handle != 0L) {
            Native.sourceFree(handle)
            handle = 0L
        }
    }
}

/**
 * 聚合句柄：持有 0..N 个已登录的源，条目 id 形如 `<sourceId>:<itemId>`。
 *
 * 界面只跟它打交道。核心内部的句柄是 `Mutex` 保护的，多线程调用安全。
 */
class MediaHub private constructor(private var handle: Long) : Closeable {

    companion object {
        fun open(): MediaHub? {
            val handle = Native.hubNew()
            return if (handle == 0L) null else MediaHub(handle)
        }
    }

    private fun raw(): Long {
        check(handle != 0L) { "MediaHub 已关闭" }
        return handle
    }

    // —— 建连 ——

    /** 加一个源并登录。失败抛 [CoreException]，已加进来的源不受影响。 */
    fun add(config: SourceConfig): SourceInfo =
        decodeEnvelope(Native.hubAdd(raw(), CoreJson.format.encodeToString(SourceConfig.serializer(), config)))

    /** 并行建连，全部结束后按入参顺序返回（单个失败不抛）。 */
    fun addMany(configs: List<SourceConfig>): List<SourceConnection> = decodeEnvelope(
        Native.hubAddMany(raw(), CoreJson.format.encodeToString(ListSerializer(SourceConfig.serializer()), configs)),
    )

    /**
     * 并行建连，每连好一个就回调一次（回调来自建连线程）。
     *
     * 注意：回调里是**裸的 [SourceConnection] 对象**，没有 `{ok,data}` 外壳
     * （核心 `dv_hub_add_many_stream` 逐条 emit 的就是这个结构）；返回值才是外壳。
     * 界面别在回调里直接改 UI 状态，转主线程再做。
     */
    fun addManyStream(
        configs: List<SourceConfig>,
        onEach: (SourceConnection) -> Unit,
    ): List<SourceConnection> {
        val listener = SourceConnectListener { json ->
            runCatching { CoreJson.format.decodeFromString<SourceConnection>(json) }
                .getOrNull()
                ?.let(onEach)
        }
        return decodeEnvelope(
            Native.hubAddManyStream(
                raw(),
                CoreJson.format.encodeToString(ListSerializer(SourceConfig.serializer()), configs),
                listener,
            ),
        )
    }

    /** 已连接的源，用于设置页显示状态。 */
    fun sources(): List<SourceInfo> = decodeEnvelope(Native.hubSources(raw()))

    // —— 浏览 ——

    fun libraries(): List<MediaLibrary> = decodeEnvelope(Native.hubLibraries(raw()))

    fun items(
        libraryId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = decodeEnvelope(
        Native.hubItems(raw(), libraryId, page, pageSize, query?.let { CoreJson.format.encodeToString(ListQuery.serializer(), it) }),
    )

    /** 聚合搜索：按标题去重、合并多来源；失败的源在 `failed` 里，不抛。 */
    fun search(query: String): SearchResult = decodeEnvelope(Native.hubSearch(raw(), query))

    /** 同一部片在各源的条目（搜索结果切源用）。 */
    fun itemSources(itemId: String): List<ItemSource> = decodeEnvelope(Native.hubItemSources(raw(), itemId))

    fun children(
        parentId: String,
        page: Int = 1,
        pageSize: Int = 60,
        query: ListQuery? = null,
    ): Page<MediaItem> = decodeEnvelope(
        Native.hubChildren(raw(), parentId, page, pageSize, query?.let { CoreJson.format.encodeToString(ListQuery.serializer(), it) }),
    )

    fun genres(scopeId: String): List<Genre> = decodeEnvelope(Native.hubGenres(raw(), scopeId))

    fun detail(itemId: String): MediaDetail = decodeEnvelope(Native.hubDetail(raw(), itemId))

    fun personWorks(personId: String): List<MediaItem> = decodeEnvelope(Native.hubPersonWorks(raw(), personId))

    fun people(itemId: String): List<Person> = decodeEnvelope(Native.hubPeople(raw(), itemId))

    fun mediaInfo(itemId: String): MediaInfo = decodeEnvelope(Native.hubMediaInfo(raw(), itemId))

    // —— 播放 ——

    fun playSource(itemId: String): PlaySource = decodeEnvelope(Native.hubPlaySource(raw(), itemId))

    fun reportProgress(itemId: String, positionSeconds: Long, durationSeconds: Long) =
        expectOk(Native.hubReportProgress(raw(), itemId, positionSeconds, durationSeconds))

    fun reportStopped(itemId: String, positionSeconds: Long, durationSeconds: Long) =
        expectOk(Native.hubReportStopped(raw(), itemId, positionSeconds, durationSeconds))

    // —— 记录 / 收藏 ——

    fun setFavorite(itemId: String, favorite: Boolean) =
        expectOk(Native.hubSetFavorite(raw(), itemId, if (favorite) 1 else 0))

    fun setWatched(itemId: String, watched: Boolean) =
        expectOk(Native.hubSetWatched(raw(), itemId, if (watched) 1 else 0))

    fun removeRecord(itemId: String) = expectOk(Native.hubRemoveRecord(raw(), itemId))

    fun favorites(page: Int = 1, pageSize: Int = 60): Page<MediaItem> =
        decodeEnvelope(Native.hubFavorites(raw(), page, pageSize))

    fun records(): List<PlayRecord> = decodeEnvelope(Native.hubRecords(raw()))

    // —— 图片 ——

    fun imageSource(path: String): ImageSource = decodeEnvelope(Native.hubImageSource(raw(), path))

    override fun close() {
        if (handle != 0L) {
            Native.hubFree(handle)
            handle = 0L
        }
    }
}
