package com.dvplayer.core

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import android.view.Display
import org.json.JSONArray
import org.json.JSONObject

/**
 * 设备能力快照（A1 的产物）。
 *
 * 只用 Android 原生 API 采集：`MediaCodecList`、`Display` 的 HDR / 模式、
 * `AudioManager` 的输出设备编码。刻意不依赖 `isHardwareAccelerated`
 * 这类 API 29+ 的方法——A1 要跑的低端机可能停在 Android 9。
 *
 * 用途：A7 的路由（HDR / 直通例外）与 A1 的结论表都从这里取数。
 */
data class DeviceProfile(
    val json: String,
    val summary: List<String>,
)

object Capabilities {

    private const val TAG = "DvCaps"

    fun collect(context: Context): DeviceProfile {
        val root = JSONObject()
        root.put("manufacturer", Build.MANUFACTURER)
        root.put("model", Build.MODEL)
        root.put("device", Build.DEVICE)
        root.put("hardware", Build.HARDWARE)
        root.put("release", Build.VERSION.RELEASE)
        root.put("sdk", Build.VERSION.SDK_INT)
        root.put("abi", Build.SUPPORTED_ABIS.firstOrNull() ?: "?")
        root.put("gles", glesVersion(context))
        root.put("pip", hasPip(context))

        val display = displayJson(context)
        root.put("display", display)
        root.put("codecs", codecsJson())
        root.put("audioCodecs", audioDecodersJson())
        root.put("tunneling", tunnelingJson())
        root.put("audio", audioJson(context))

        val json = root.toString(2)
        Log.i(TAG, json)

        return DeviceProfile(json = json, summary = summaryOf(root, display))
    }

    private fun glesVersion(context: Context): String {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.deviceConfigurationInfo.glEsVersion ?: "?"
    }

    private fun hasPip(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @Suppress("DEPRECATION") // getDefaultDisplay：API 30 才弃用，基线要兼容 26
    private fun displayJson(context: Context): JSONObject {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        val display = wm.defaultDisplay
        val mode = display.mode

        val obj = JSONObject()
        obj.put("width", mode.physicalWidth)
        obj.put("height", mode.physicalHeight)
        obj.put("fps", mode.refreshRate.toDouble().round1())

        val modes = JSONArray()
        display.supportedModes.forEach { m ->
            modes.put(
                JSONObject()
                    .put("w", m.physicalWidth)
                    .put("h", m.physicalHeight)
                    .put("fps", m.refreshRate.toDouble().round1()),
            )
        }
        obj.put("modes", modes)

        val hdr = display.hdrCapabilities
        val types = JSONArray()
        hdr?.supportedHdrTypes?.forEach { types.put(hdrName(it)) }
        obj.put("hdr", types)
        obj.put("hdrMaxLuminance", hdr?.desiredMaxLuminance ?: -1)
        obj.put("hdrMaxAverageLuminance", hdr?.desiredMaxAverageLuminance ?: -1)
        obj.put("wideColorGamut", display.isWideColorGamut)
        return obj
    }

    private fun hdrName(type: Int): String = when (type) {
        Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "dolby_vision"
        Display.HdrCapabilities.HDR_TYPE_HDR10 -> "hdr10"
        Display.HdrCapabilities.HDR_TYPE_HLG -> "hlg"
        Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "hdr10_plus"
        else -> "unknown($type)"
    }

    /** mime → 解码器名。软解（OMX.google / c2.android）也留着，方便看「硬解有没有」。 */
    private fun codecsJson(): JSONObject {
        val byMime = linkedMapOf<String, MutableList<String>>()
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.forEach { info ->
            info.supportedTypes
                .filter { it.startsWith("video/") }
                .forEach { mime -> byMime.getOrPut(mime) { mutableListOf() }.add(info.name) }
        }

        val obj = JSONObject()
        byMime.forEach { (mime, names) ->
            obj.put(mime, JSONArray(names.sorted()))
        }
        return obj
    }

    /** 系统自带的音频解码器（DTS / TrueHD 通常没有，需要 FFmpeg 扩展）。 */
    private fun audioDecodersJson(): JSONObject {
        val byMime = linkedMapOf<String, MutableList<String>>()
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.forEach { info ->
            if (info.isEncoder) return@forEach
            info.supportedTypes
                .filter { it.startsWith("audio/") }
                .forEach { mime -> byMime.getOrPut(mime) { mutableListOf() }.add(info.name) }
        }
        val obj = JSONObject()
        byMime.forEach { (mime, names) -> obj.put(mime, JSONArray(names.sorted())) }
        return obj
    }

    /**
     * tunneling（A6 / B3）：解码器是否声明了 FEATURE_TunneledPlayback。
     * 手机一般没有，TV / 盒子才有；A7 的路由需要这个结论。
     */
    private fun tunnelingJson(): JSONObject {
        val codecs = mutableListOf<String>()
        MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.forEach { info ->
            if (info.isEncoder) return@forEach
            info.supportedTypes
                .filter { it.startsWith("video/") }
                .forEach { mime ->
                    val caps = runCatching { info.getCapabilitiesForType(mime) }.getOrNull()
                        ?: return@forEach
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                        caps.isFeatureSupported(
                            MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback,
                        )
                    ) {
                        codecs.add("${info.name}:$mime")
                    }
                }
        }
        return JSONObject()
            .put("supported", codecs.isNotEmpty())
            .put("codecs", JSONArray(codecs.distinct()))
    }

    private fun audioJson(context: Context): JSONObject {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = JSONArray()
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).forEach { device ->
            devices.put(
                JSONObject()
                    .put("type", deviceType(device.type))
                    .put("name", device.productName?.toString() ?: "")
                    .put("encodings", encodings(device.encodings)),
            )
        }
        return JSONObject().put("outputs", devices)
    }

    private fun deviceType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker_safe"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb_accessory"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt_a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bt_sco"
        AudioDeviceInfo.TYPE_HDMI -> "hdmi"
        AudioDeviceInfo.TYPE_HDMI_ARC -> "hdmi_arc"
        AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi_earc"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "line_analog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line_digital"
        AudioDeviceInfo.TYPE_AUX_LINE -> "aux_line"
        AudioDeviceInfo.TYPE_TELEPHONY -> "telephony"
        AudioDeviceInfo.TYPE_IP -> "ip"
        AudioDeviceInfo.TYPE_BUS -> "bus"
        AudioDeviceInfo.TYPE_DOCK -> "dock"
        else -> "type($type)"
    }

    /** 直通能力看这里：AC3 / EAC3 / DTS / DTS-HD / TrueHD 有没有被 HDMI 端声明。 */
    private fun encodings(encodings: IntArray?): JSONArray {
        val arr = JSONArray()
        encodings?.forEach { arr.put(encodingName(it)) }
        return arr
    }

    private fun encodingName(encoding: Int): String = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> "pcm_16"
        AudioFormat.ENCODING_PCM_FLOAT -> "pcm_float"
        AudioFormat.ENCODING_AC3 -> "ac3"
        AudioFormat.ENCODING_E_AC3 -> "eac3"
        AudioFormat.ENCODING_DTS -> "dts"
        AudioFormat.ENCODING_DTS_HD -> "dts_hd"
        AudioFormat.ENCODING_DOLBY_TRUEHD -> "truehd"
        AudioFormat.ENCODING_E_AC3_JOC -> "eac3_joc"
        AudioFormat.ENCODING_AC4 -> "ac4"
        else -> "enc($encoding)"
    }

    private fun summaryOf(root: JSONObject, display: JSONObject): List<String> {
        val hdr = display.getJSONArray("hdr")
        val hdrText = if (hdr.length() == 0) "SDR" else (0 until hdr.length()).joinToString("/") { hdr.getString(it) }

        val codecs = root.getJSONObject("codecs")
        val mimes = codecs.keys().asSequence().sorted().joinToString(" ")

        val outputs = root.getJSONObject("audio").getJSONArray("outputs")
        val passthrough = mutableSetOf<String>()
        for (i in 0 until outputs.length()) {
            val enc = outputs.getJSONObject(i).getJSONArray("encodings")
            for (j in 0 until enc.length()) {
                val name = enc.getString(j)
                if (name in PASS_THROUGH) passthrough.add(name)
            }
        }

        val audioCodecs = root.getJSONObject("audioCodecs")
        val audioMimes = audioCodecs.keys().asSequence().sorted().joinToString(" ")
        val tunneling = root.getJSONObject("tunneling").getBoolean("supported")

        return listOf(
            "${root.getString("manufacturer")} ${root.getString("model")} · Android ${root.getString("release")} (API ${root.getInt("sdk")})",
            "${root.getString("abi")} · ${root.getString("hardware")} · GLES ${root.getString("gles")}",
            "${display.getInt("width")}×${display.getInt("height")} @ ${display.getDouble("fps")}Hz · $hdrText · PiP ${if (root.getBoolean("pip")) "有" else "无"}",
            "解码 mime：$mimes",
            "音频解码 mime：$audioMimes",
            "tunneling：${if (tunneling) "支持" else "不支持"}",
            "直通：${if (passthrough.isEmpty()) "无" else passthrough.joinToString("/")}",
        )
    }

    private val PASS_THROUGH = setOf("ac3", "eac3", "dts", "dts_hd", "truehd", "eac3_joc", "ac4")

    private fun Double.round1(): Double = Math.round(this * 10.0) / 10.0
}
