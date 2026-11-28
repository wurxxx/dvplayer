package com.dvplayer.player

/**
 * 播放控制（A4 / A7）：把「用哪个内核、从哪开始播、出错换谁」从验证页 /
 * 播放页搬到这里，让壳层只负责建 Surface、传事件。
 *
 * 只放决策，不碰 Surface / Activity：
 * - 手动指定内核优先；`auto` 才走 [EngineRouter]（带超时回退）
 * - 续播：显式 `seek_to` 优先，其次上次位置；片尾 5 秒内不续播
 * - Media3 起播失败回退 mpv，只回退一次
 * - 切换内核 = 另一个内核
 *
 * 时间单位毫秒，和 [PlayerEngine] 一致。
 */
class PlaybackController(
    private val memory: ProgressStore? = null,
    private val router: Router? = null,
) {

    fun interface Router {
        fun choose(url: String): RoutingPolicy.Decision
    }

    data class EngineChoice(val engine: EngineId, val reason: String?)

    sealed interface Resume {
        /** 显式指定（切内核 / 重试），要连倍速与暂停态一起恢复。 */
        data class Explicit(val positionMs: Long) : Resume

        /** 上次进度。 */
        data class Saved(val positionMs: Long) : Resume
    }

    sealed interface Recovery {
        data class FallbackToMpv(val positionMs: Long) : Recovery
        data object None : Recovery
    }

    /**
     * @param manual 命令行 / 用户明确指定的内核（`codec` 这类非双内核值由壳层
     *   自己处理，不进这里）
     * @param auto 是否允许按片源能力自动路由
     */
    fun chooseEngine(
        url: String,
        manual: EngineId?,
        auto: Boolean,
        timeoutMs: Long = 4_000,
    ): EngineChoice {
        manual?.let { return EngineChoice(it, null) }
        if (!auto) return EngineChoice(EngineId.MPV, null)
        val router = this.router
            ?: return EngineChoice(EngineId.MPV, "未配置路由，回退 mpv")

        var decision: RoutingPolicy.Decision? = null
        val thread = Thread {
            decision = runCatching { router.choose(url) }.getOrNull()
        }.apply { isDaemon = true }
        thread.start()
        thread.join(timeoutMs)
        return decision?.let { EngineChoice(it.engine, it.reason) }
            ?: EngineChoice(EngineId.MPV, "路由超时或失败，回退 mpv")
    }

    /**
     * 起播位置。返回 null 表示从头播。
     *
     * @param explicitMs `seek_to`，小于 0 表示没有显式位置
     */
    fun resume(
        url: String,
        explicitMs: Long,
        durationMs: Long,
    ): Resume? {
        if (durationMs <= 0) return null
        if (explicitMs >= 0) return Resume.Explicit(explicitMs)

        val saved = memory?.position(url) ?: return null
        if (saved <= MIN_RESUME_MS) return null
        // 已经到片尾附近，重播没意义；和 [PlaybackMemory] 的清理边界一致。
        if (saved >= durationMs - END_MARGIN_MS) return null
        return Resume.Saved(saved)
    }

    fun save(url: String, positionMs: Long, durationMs: Long) {
        memory?.save(url, positionMs, durationMs)
    }

    /**
     * 起播 / 播放出错后要不要换内核。
     *
     * mpv 失败通常是真的打不开（缺库、文件损坏），换 Media3 没有意义；
     * 只允许 Media3 → mpv 一次。
     */
    fun recovery(engine: EngineId, fallbackTried: Boolean, positionMs: Long): Recovery =
        if (engine == EngineId.MEDIA3 && !fallbackTried) {
            Recovery.FallbackToMpv(positionMs.coerceAtLeast(0))
        } else {
            Recovery.None
        }

    /** 切内核：两个内核之间直接对换。 */
    fun otherEngine(engine: EngineId): EngineId =
        if (engine == EngineId.MEDIA3) EngineId.MPV else EngineId.MEDIA3

    private companion object {
        const val MIN_RESUME_MS = 3_000L
        const val END_MARGIN_MS = 5_000L
    }
}
