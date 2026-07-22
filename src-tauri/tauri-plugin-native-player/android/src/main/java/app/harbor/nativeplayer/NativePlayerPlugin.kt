package app.harbor.nativeplayer

import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.WebView
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

// Android counterpart of the iOS native-player plugin: an ExoPlayer surface
// placed BEHIND the (transparent) Tauri WebView. Implements the exact same
// command + event contract as the Swift/libmpv side, so the JS bridge
// (src/lib/player/native.ts) works unchanged:
//   commands: probe/load/play/pause/stop/seek/setVolume/setMuted/setRate/
//             setAudioTrack/setSubtitleTrack/addSubtitle/setProperty/
//             lockLandscape/unlockOrientation/exitProbe/mainPing/probeLog
//   events:   "time"   { positionSec, durationSec }
//             "status" { status, buffering, durationSec, rate, audioTracks,
//                        subtitleTracks, videoWidth, videoHeight }
//             "debug"  { msg }
// ExoPlayer uses MediaCodec (hardware) decode, which keeps the phone cool —
// the same reason the platform players are efficient.

@InvokeArg
class LoadArgs {
    var url: String = ""
    var startAtSec: Double? = null
}

@InvokeArg
class SeekArgs { var sec: Double = 0.0 }

@InvokeArg
class VolumeArgs { var volume: Double = 1.0 }

@InvokeArg
class MutedArgs { var muted: Boolean = false }

@InvokeArg
class RateArgs { var rate: Double = 1.0 }

@InvokeArg
class TrackArgs { var id: Int = -1 }

@InvokeArg
class SubtitleArgs {
    var url: String = ""
    var select: Boolean? = null
}

@InvokeArg
class SetPropArgs {
    var name: String = ""
    var value: String = ""
}

@InvokeArg
class ProbeLogArgs { var msg: String = "" }

@SuppressLint("UnsafeOptInUsageError")
@TauriPlugin
class NativePlayerPlugin(private val activity: Activity) : Plugin(activity) {
    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var webView: WebView? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null
    private var lastVolume = 1.0f
    private var currentUrl = ""
    private var subtitleConfigs = mutableListOf<MediaItem.SubtitleConfiguration>()
    // Last subtitle style pushed from JS (mpv property names), replayed onto
    // each new PlayerView so the look survives a player rebuild.
    private val subProps = mutableMapOf<String, String>()

    override fun load(webView: WebView) {
        super.load(webView)
        this.webView = webView
    }

    // MARK: - lifecycle helpers (main thread only)

    private fun ensurePlayer() {
        if (player != null) return
        val wv = webView ?: return
        val parent = wv.parent as? ViewGroup ?: return

        // Browser-like UA: debrid resolvers 500 on library UAs, and follow
        // http<->https redirects to the final CDN file.
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(
                "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
                    "Chrome/124.0.0.0 Mobile Safari/537.36"
            )
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(15000)
        val dataSource = DefaultDataSource.Factory(activity, http)

        val p = ExoPlayer.Builder(activity)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
        p.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true
        )
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) = emitStatus()
            override fun onIsPlayingChanged(isPlaying: Boolean) = emitStatus()
            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) = emitStatus()
            override fun onVideoSizeChanged(size: VideoSize) = emitStatus()
            override fun onPlayerError(error: PlaybackException) {
                debug("exo error: ${error.errorCodeName} ${error.message ?: ""}")
                val data = JSObject()
                data.put("status", "error")
                trigger("status", data)
            }
        })

        val view = PlayerView(activity)
        view.useController = false
        view.setBackgroundColor(Color.BLACK)
        view.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        view.player = p
        view.visibility = android.view.View.GONE
        // Behind the webview; the webview goes transparent so the page's
        // player screen (which draws no background there) reveals the video.
        parent.addView(view, 0)
        wv.setBackgroundColor(Color.TRANSPARENT)

        player = p
        playerView = view
        applySubtitleStyle()   // replay whatever JS already pushed
        startTicker()
    }

    private fun startTicker() {
        if (ticker != null) return
        val r = object : Runnable {
            override fun run() {
                val p = player
                if (p != null) {
                    val data = JSObject()
                    data.put("positionSec", p.currentPosition.coerceAtLeast(0) / 1000.0)
                    data.put("durationSec", if (p.duration > 0) p.duration / 1000.0 else 0.0)
                    trigger("time", data)
                }
                mainHandler.postDelayed(this, 500)
            }
        }
        ticker = r
        mainHandler.postDelayed(r, 500)
    }

    private fun stopTicker() {
        ticker?.let { mainHandler.removeCallbacks(it) }
        ticker = null
    }

    private fun debug(msg: String) {
        val data = JSObject()
        data.put("msg", msg)
        trigger("debug", data)
    }

    private fun emitStatus() {
        val p = player ?: return
        val state = p.playbackState
        val status = when {
            state == Player.STATE_ENDED -> "ended"
            state == Player.STATE_BUFFERING -> "loading"
            p.isPlaying -> "playing"
            else -> "paused"
        }
        val data = JSObject()
        data.put("status", status)
        data.put("buffering", state == Player.STATE_BUFFERING)
        data.put("durationSec", if (p.duration > 0) p.duration / 1000.0 else 0.0)
        data.put("rate", p.playbackParameters.speed.toDouble())
        val audio = JSArray()
        val subs = JSArray()
        for ((gi, group) in p.currentTracks.groups.withIndex()) {
            val type = group.type
            if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_TEXT) continue
            for (ti in 0 until group.length) {
                val format = group.getTrackFormat(ti)
                val obj = JSObject()
                obj.put("id", gi * 1000 + ti)
                val label = format.label ?: format.language ?: ""
                obj.put("label", if (label.isEmpty()) "Track ${gi * 1000 + ti}" else label)
                obj.put("lang", format.language ?: "")
                obj.put("title", format.label ?: "")
                obj.put("codec", format.sampleMimeType ?: "")
                obj.put("selected", group.isTrackSelected(ti))
                if (type == C.TRACK_TYPE_AUDIO) audio.put(obj) else subs.put(obj)
            }
        }
        data.put("audioTracks", audio)
        data.put("subtitleTracks", subs)
        data.put("videoWidth", p.videoSize.width)
        data.put("videoHeight", p.videoSize.height)
        trigger("status", data)
        // Keep the screen awake only while actually playing.
        playerView?.keepScreenOn = (status == "playing" || status == "loading")
    }

    private fun mediaItem(url: String): MediaItem {
        val builder = MediaItem.Builder().setUri(url)
        if (subtitleConfigs.isNotEmpty()) builder.setSubtitleConfigurations(subtitleConfigs)
        return builder.build()
    }

    private fun subtitleMime(url: String): String {
        val u = url.substringBefore('?').lowercase()
        return when {
            u.endsWith(".vtt") -> MimeTypes.TEXT_VTT
            u.endsWith(".ass") || u.endsWith(".ssa") -> MimeTypes.TEXT_SSA
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    // MARK: - commands

    @Command
    fun probe(invoke: Invoke) {
        val ret = JSObject()
        ret.put("available", true)
        invoke.resolve(ret)
    }

    @Command
    fun load(invoke: Invoke) {
        val args = invoke.parseArgs(LoadArgs::class.java)
        activity.runOnUiThread {
            ensurePlayer()
            val p = player ?: return@runOnUiThread invoke.reject("player unavailable")
            debug("load: begin ${args.url.take(96)}")
            subtitleConfigs.clear()
            currentUrl = args.url
            playerView?.visibility = android.view.View.VISIBLE
            p.setMediaItem(mediaItem(args.url), ((args.startAtSec ?: 0.0) * 1000).toLong())
            p.prepare()
            p.playWhenReady = true
            debug("load: prepared")
            invoke.resolve()
        }
    }

    @Command
    fun play(invoke: Invoke) {
        activity.runOnUiThread { player?.play(); invoke.resolve() }
    }

    @Command
    fun pause(invoke: Invoke) {
        activity.runOnUiThread { player?.pause(); invoke.resolve() }
    }

    @Command
    fun stop(invoke: Invoke) {
        activity.runOnUiThread {
            debug("stop: begin")
            player?.pause()
            player?.clearMediaItems()
            playerView?.visibility = android.view.View.GONE
            playerView?.keepScreenOn = false
            subtitleConfigs.clear()
            currentUrl = ""
            debug("stop: end")
            invoke.resolve()
        }
    }

    @Command
    fun seek(invoke: Invoke) {
        val args = invoke.parseArgs(SeekArgs::class.java)
        activity.runOnUiThread {
            player?.seekTo((args.sec * 1000).toLong())
            invoke.resolve()
        }
    }

    @Command
    fun setVolume(invoke: Invoke) {
        val args = invoke.parseArgs(VolumeArgs::class.java)
        activity.runOnUiThread {
            // JS may send 0..1 (html5 semantics) or 0..100 (mpv semantics).
            val v = if (args.volume > 1.5) args.volume / 100.0 else args.volume
            lastVolume = v.toFloat().coerceIn(0f, 1f)
            player?.volume = lastVolume
            invoke.resolve()
        }
    }

    @Command
    fun setMuted(invoke: Invoke) {
        val args = invoke.parseArgs(MutedArgs::class.java)
        activity.runOnUiThread {
            val p = player ?: return@runOnUiThread invoke.resolve()
            if (args.muted) {
                if (p.volume > 0f) lastVolume = p.volume
                p.volume = 0f
            } else {
                p.volume = if (lastVolume > 0f) lastVolume else 1f
            }
            invoke.resolve()
        }
    }

    @Command
    fun setRate(invoke: Invoke) {
        val args = invoke.parseArgs(RateArgs::class.java)
        activity.runOnUiThread {
            player?.setPlaybackSpeed(args.rate.toFloat().coerceIn(0.25f, 4f))
            invoke.resolve()
        }
    }

    private fun selectTrack(type: Int, id: Int) {
        val p = player ?: return
        if (id < 0) {
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(type, true)
                .build()
            return
        }
        val gi = id / 1000
        val ti = id % 1000
        val groups = p.currentTracks.groups
        if (gi >= groups.size) return
        val group = groups[gi]
        if (group.type != type || ti >= group.length) return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, ti))
            .build()
    }

    @Command
    fun setAudioTrack(invoke: Invoke) {
        val args = invoke.parseArgs(TrackArgs::class.java)
        activity.runOnUiThread { selectTrack(C.TRACK_TYPE_AUDIO, args.id); invoke.resolve() }
    }

    @Command
    fun setSubtitleTrack(invoke: Invoke) {
        val args = invoke.parseArgs(TrackArgs::class.java)
        activity.runOnUiThread { selectTrack(C.TRACK_TYPE_TEXT, args.id); invoke.resolve() }
    }

    @Command
    fun addSubtitle(invoke: Invoke) {
        val args = invoke.parseArgs(SubtitleArgs::class.java)
        activity.runOnUiThread {
            val p = player ?: return@runOnUiThread invoke.resolve()
            val select = args.select ?: true
            val config = MediaItem.SubtitleConfiguration.Builder(Uri.parse(args.url))
                .setMimeType(subtitleMime(args.url))
                .setSelectionFlags(if (select) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
            subtitleConfigs.add(config)
            if (currentUrl.isNotEmpty()) {
                val pos = p.currentPosition
                val playing = p.playWhenReady
                p.setMediaItem(mediaItem(currentUrl), pos)
                p.prepare()
                p.playWhenReady = playing
                if (select) {
                    p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .build()
                }
            }
            invoke.resolve()
        }
    }

    // The shared subtitle-style code speaks mpv property names. Translate the
    // ones that have an ExoPlayer equivalent onto the SubtitleView; the rest
    // (font family, line spacing, ASS margin knobs) are accepted and ignored.
    @Command
    fun setProperty(invoke: Invoke) {
        val args = invoke.parseArgs(SetPropArgs::class.java)
        activity.runOnUiThread {
            subProps[args.name] = args.value
            applySubtitleStyle()
            invoke.resolve()
        }
    }

    /// mpv colors arrive as "#AARRGGBB" (see mpvColor in sub-style.ts).
    private fun mpvColor(value: String?, fallback: Int): Int {
        val hex = value?.removePrefix("#") ?: return fallback
        return try {
            when (hex.length) {
                8 -> {
                    val a = hex.substring(0, 2).toInt(16)
                    val r = hex.substring(2, 4).toInt(16)
                    val g = hex.substring(4, 6).toInt(16)
                    val b = hex.substring(6, 8).toInt(16)
                    Color.argb(a, r, g, b)
                }
                6 -> Color.parseColor("#$hex")
                else -> fallback
            }
        } catch (e: Exception) {
            fallback
        }
    }

    private fun applySubtitleStyle() {
        val view = playerView?.subtitleView ?: return
        val fg = mpvColor(subProps["sub-color"], Color.WHITE)
        val bg = mpvColor(subProps["sub-back-color"], Color.TRANSPARENT)
        val edgeColor = mpvColor(subProps["sub-border-color"], Color.BLACK)
        val isBox = Color.alpha(bg) > 0
        // Desktop keeps the file's own ASS styling by default (override = "no"),
        // which libass draws as bold white text with a heavy black outline.
        // ExoPlayer cannot reproduce ASS styling, so approximate that look
        // instead of falling through to bare text.
        val keepOriginal = subProps["sub-ass-override"].let { it == null || it == "no" }
        val bold = subProps["sub-bold"] == "yes" || keepOriginal
        // ExoPlayer's DROP_SHADOW is barely visible at phone sizes and reads as
        // "no styling at all" against bright scenes; OUTLINE is both the legible
        // choice and what the desktop render looks like. Box styling still wins
        // when the user asked for a background.
        val edgeType =
            if (isBox) CaptionStyleCompat.EDGE_TYPE_NONE
            else CaptionStyleCompat.EDGE_TYPE_OUTLINE
        val typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT

        view.setStyle(
            CaptionStyleCompat(fg, bg, Color.TRANSPARENT, edgeType, edgeColor, typeface)
        )
        // Never let the embedded styling through: ExoPlayer renders only a
        // fraction of it, which is what made subtitles ignore the settings.
        view.setApplyEmbeddedStyles(false)

        // sub-scale is 1.0 at the app's 32px baseline; SubtitleView sizes text
        // as a fraction of view height (0.0533 is its default).
        val scale = subProps["sub-scale"]?.toFloatOrNull() ?: 1f
        view.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * scale)

        // sub-margin-y is a 0..100 distance from the bottom in the app's model.
        subProps["sub-margin-y"]?.toFloatOrNull()?.let { margin ->
            view.setBottomPaddingFraction((margin / 100f).coerceIn(0f, 0.5f))
        }
    }

    @Command
    fun lockLandscape(invoke: Invoke) {
        activity.runOnUiThread {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            invoke.resolve()
        }
    }

    @Command
    fun unlockOrientation(invoke: Invoke) {
        activity.runOnUiThread {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            invoke.resolve()
        }
    }

    @Command
    fun exitProbe(invoke: Invoke) {
        val ret = JSObject()
        ret.put("text", "")
        invoke.resolve(ret)
    }

    @Command
    fun mainPing(invoke: Invoke) {
        mainHandler.post { invoke.resolve() }
    }

    @Command
    fun probeLog(invoke: Invoke) {
        invoke.parseArgs(ProbeLogArgs::class.java)
        invoke.resolve()
    }
}
