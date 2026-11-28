package com.dvplayer.core

/**
 * 共享核心的 native 入口（`libdvplayer_media_jni.so`）。
 *
 * 这一层只做类型搬运：句柄是 `Long`（`*mut SourceHandle` / `*mut HubHandle`），
 * 字符串参数可为 null，返回的都是核心的 JSON 外壳 `{"ok":…,"data":…}`。
 * 业务 API 在 [MediaHub] / [MediaSourceHandle] / [DvCore]，别在界面里直接调这里。
 *
 * **方法不能标 `internal`**：Kotlin 会把 internal 成员改名成 `coreVersion$core_debug`，
 * JNI 就找不到 `Java_com_dvplayer_core_Native_coreVersion` 了。要隐藏请用注释/分层约定，
 * 别用可见性修饰符。
 */
object Native {
    init {
        System.loadLibrary("dvplayer_media_jni")
    }

    /// JNI 自检：证明 jniLibs 打包与 `System.loadLibrary` 这条链是通的。
    external fun version(): String

    // —— 单源 ——
    external fun sourceKinds(): String
    external fun sourceCreate(config: String): Long
    external fun sourceFree(handle: Long)
    external fun connect(handle: Long): String
    external fun libraries(handle: Long): String
    external fun items(
        handle: Long,
        libraryId: String,
        page: Int,
        pageSize: Int,
        query: String?,
    ): String

    external fun children(
        handle: Long,
        parentId: String,
        page: Int,
        pageSize: Int,
        query: String?,
    ): String

    external fun records(handle: Long): String
    external fun reportProgress(
        handle: Long,
        itemId: String,
        position: Long,
        duration: Long,
    ): String

    external fun reportStopped(
        handle: Long,
        itemId: String,
        position: Long,
        duration: Long,
    ): String

    external fun itemDetail(handle: Long, itemId: String): String
    external fun playSource(handle: Long, itemId: String): String
    external fun imageSource(handle: Long, path: String): String

    /// DV P7 的 FEL / MEL 判定；不依赖 hub。
    external fun probeDovi(url: String, headers: String?, proxy: String?): String

    // —— 聚合层 ——
    external fun hubNew(): Long
    external fun hubFree(handle: Long)
    external fun hubAdd(handle: Long, config: String): String
    external fun hubAddMany(handle: Long, configs: String): String

    /// `listener.onSource(json)` 从建连线程回调，实现方自己切线程。
    external fun hubAddManyStream(
        handle: Long,
        configs: String,
        listener: SourceConnectListener,
    ): String

    external fun hubSources(handle: Long): String
    external fun hubLibraries(handle: Long): String
    external fun hubItems(
        handle: Long,
        libraryId: String,
        page: Int,
        pageSize: Int,
        query: String?,
    ): String

    external fun hubSearch(handle: Long, query: String): String
    external fun hubItemSources(handle: Long, itemId: String): String
    external fun hubChildren(
        handle: Long,
        parentId: String,
        page: Int,
        pageSize: Int,
        query: String?,
    ): String

    external fun hubGenres(handle: Long, scopeId: String): String
    external fun hubDetail(handle: Long, itemId: String): String
    external fun hubPersonWorks(handle: Long, personId: String): String
    external fun hubPeople(handle: Long, itemId: String): String
    external fun hubMediaInfo(handle: Long, itemId: String): String
    external fun hubPlaySource(handle: Long, itemId: String): String
    external fun hubReportProgress(
        handle: Long,
        itemId: String,
        position: Long,
        duration: Long,
    ): String

    external fun hubReportStopped(
        handle: Long,
        itemId: String,
        position: Long,
        duration: Long,
    ): String

    external fun hubSetFavorite(handle: Long, itemId: String, favorite: Int): String
    external fun hubSetWatched(handle: Long, itemId: String, watched: Int): String
    external fun hubRemoveRecord(handle: Long, itemId: String): String
    external fun hubFavorites(handle: Long, page: Int, pageSize: Int): String
    external fun hubRecords(handle: Long): String
    external fun hubImageSource(handle: Long, path: String): String

    /// 核心库版本（`dv_version`，走 JSON 外壳）。
    external fun coreVersion(): String
}

/**
 * `hubAddManyStream` 的逐源回调。
 *
 * 回调来自 Rust 的建连线程（可能多个线程同时进来），实现方要自己保证线程安全，
 * 界面侧通常转主线程再更新状态。
 */
fun interface SourceConnectListener {
    fun onSource(json: String)
}
