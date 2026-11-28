package com.dvplayer.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * 播放期的音频焦点与耳机拔出处理。
 *
 * 不处理会有很明显的体验问题：来电 / 别的 App 放音频时两边一起响；
 * 拔耳机时声音突然从外放炸出来。
 *
 * - 拿到焦点前不播；永久失去焦点就暂停
 * - 短暂失去（导航播报、来电铃声）时压低音量（duck），结束后恢复
 * - 拔出耳机 / 蓝牙断开：直接暂停，不继续外放
 */
class PlaybackAudioControl(
    context: Context,
    /** 内核要求暂停（失去焦点 / 拔耳机）。 */
    private val onPause: () -> Unit,
    /** 内核要求恢复播放（焦点回来且用户本来在播）。 */
    private val onResume: () -> Unit,
    /** 压音量：1f 正常，0.2f 压低。 */
    private val onVolumeScale: (Float) -> Unit,
) {
    private companion object {
        const val TAG = "DvAudio"
    }

    private val appContext = context.applicationContext
    private val audio = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** 用户当前的播放意图。焦点丢了但我们不该擅自恢复（用户自己暂停过）。 */
    private var wantsPlay = true

    /** 被 duck 中，等焦点回来要还原。 */
    private var ducked = false

    private var focusRequest: AudioFocusRequest? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                Log.i(TAG, "焦点：恢复")
                if (ducked) {
                    ducked = false
                    onVolumeScale(1f)
                }
                if (wantsPlay) onResume()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.i(TAG, "焦点：短暂失去，压低")
                ducked = true
                onVolumeScale(0.2f)
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.i(TAG, "焦点：允许 duck，压低")
                ducked = true
                onVolumeScale(0.2f)
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                Log.i(TAG, "焦点：永久失去，暂停")
                wantsPlay = false
                onPause()
            }
        }
    }

    /** 耳机拔出 / 蓝牙断开：别外放。 */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                Log.i(TAG, "音频输出断开，暂停")
                wantsPlay = false
                onPause()
            }
        }
    }

    private var registered = false

    /** 起播时调用：请求焦点并开始监听耳机拔出。 */
    fun start() {
        wantsPlay = true
        requestFocus()
        if (!registered) {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(
                    noisyReceiver,
                    IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                    Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                appContext.registerReceiver(
                    noisyReceiver,
                    IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                )
            }
            registered = true
        }
    }

    /** 用户主动暂停 / 播放，同步播放意图（免得焦点事件把用户的暂停顶掉）。 */
    fun setWantsPlay(play: Boolean) {
        wantsPlay = play
        if (play) requestFocus()
    }

    /** 退出播放页：还焦点、注销广播。 */
    fun release() {
        wantsPlay = false
        if (registered) {
            runCatching { appContext.unregisterReceiver(noisyReceiver) }
            registered = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        if (ducked) {
            ducked = false
            onVolumeScale(1f)
        }
    }

    private fun requestFocus() {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                // 不要 pauseOnDuck：我们自己在 duck 回调里压音量，暂停会闪一下。
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        Log.i(TAG, "请求焦点 -> ${if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) "granted" else "denied"}")
    }
}
