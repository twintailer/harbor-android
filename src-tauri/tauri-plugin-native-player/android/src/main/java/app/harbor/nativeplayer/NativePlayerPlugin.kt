package app.harbor.nativeplayer

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import dev.jdtech.mpv.MPVLib
import java.io.File

// Native playback for Android, backed by libmpv — the same engine the desktop
// and iOS builds use. Renders into a SurfaceView placed BEHIND the (transparent)
// Tauri WebView and speaks the exact command + event contract the shared JS
// bridge (src/lib/player/native.ts) expects, so nothing on the web side changes:
//   commands: probe/load/play/pause/stop/seek/setVolume/setMuted/setRate/
//             setAudioTrack/setSubtitleTrack/addSubtitle/setProperty/
//             lockLandscape/unlockOrientation/exitProbe/mainPing/probeLog
//   events:   "time"   { positionSec, durationSec }
//             "status" { status, buffering, durationSec, rate, audioTracks,
//                        subtitleTracks, videoWidth, videoHeight }
//             "debug"  { msg }
//
// Why libmpv and not ExoPlayer (which this plugin used first): ExoPlayer plays
// the files fine, but it implements only a fraction of ASS/SSA styling, so
// subtitles never looked like the desktop no matter how the style properties
// were translated. libmpv ships libass, so `setProperty` now forwards Harbor's
// mpv property names verbatim and every subtitle setting behaves identically
// across Windows, iOS and Android.
//
// State is POLLED off a handler rather than driven by MPVLib's observer
// interface (whose shape differs between library versions) — the same approach
// the iOS plugin takes.

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

@TauriPlugin
class NativePlayerPlugin(private val activity: Activity) : Plugin(activity) {
    private var mpv: MPVLib? = null
    private var surfaceView: SurfaceView? = null
    private var surfaceReady = false
    private var mpvReady = false
    private var webView: WebView? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var ticker: Runnable? = null
    private var lastVolume = 100
    private var lastTracksSignature = ""
    // Style properties pushed before mpv existed, replayed after init.
    private val pendingProps = mutableMapOf<String, String>()
    // (url, startAtSec) requested before the surface existed; fired from
    // surfaceCreated. mpv cannot start playback without a window.
    private var pendingLoad: Pair<String, Double>? = null
    private var startedPlaying = false
    private var watchdog: Runnable? = null

    private companion object {
        const val VIDEO_OUTPUT = "gpu"
        // Must stay BELOW the web side's STUCK_AUTORETRY_MS (18s): that retry
        // reloads the player and re-arms this watchdog, so a longer timeout
        // never fires and the failure reason is never reported.
        const val LOAD_TIMEOUT_MS = 12_000L
    }

    /** Everything worth knowing when a load goes nowhere, in one line. */
    private fun diagnosticState(): String {
        val sv = surfaceView
        return "mpv=${if (mpvReady) "ready" else "not-ready"}" +
            " view=${if (sv == null) "none" else if (sv.visibility == View.VISIBLE) "visible" else "hidden"}" +
            " surface=${if (surfaceReady) "ready" else "missing"}" +
            " queued=${pendingLoad != null}"
    }

    /** Tell the web side playback failed, so it ejects instead of hanging. */
    private fun fail(reason: String) {
        debug("error: $reason")
        val data = JSObject()
        data.put("status", "error")
        // Carried through to the on-screen error so a stuck load can be
        // diagnosed from a screenshot instead of a log dump.
        data.put("message", reason)
        trigger("status", data)
    }

    /**
     * Without this a failure to start (no surface, dead link, mpv refusing the
     * stream) leaves the UI on "connecting" forever with no way to tell why.
     */
    private fun armWatchdog() {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        startedPlaying = false
        val r = Runnable {
            if (startedPlaying) return@Runnable
            // Last chance: the view may have been created after the load (the
            // webview's parent isn't always ready at plugin load). Re-check and
            // fire the queued load if a surface has since appeared.
            ensureView()
            val queued = pendingLoad
            if (queued != null && surfaceReady) {
                pendingLoad = null
                debug("watchdog: surface appeared late → loading")
                doLoad(queued.first, queued.second)
                mainHandler.postDelayed({ if (!startedPlaying) fail(diagnosticState()) }, LOAD_TIMEOUT_MS)
                return@Runnable
            }
            fail(diagnosticState())
        }
        watchdog = r
        mainHandler.postDelayed(r, LOAD_TIMEOUT_MS)
    }

    override fun load(webView: WebView) {
        super.load(webView)
        this.webView = webView
        mainHandler.post { ensureView() }
    }

    // MARK: - surface / core setup (main thread)

    private fun ensureView() {
        if (surfaceView != null) return
        val wv = webView ?: return
        val parent = wv.parent as? ViewGroup ?: return

        val sv = SurfaceView(activity)
        sv.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        sv.visibility = View.GONE
        // Surface lifecycle drives the video output, following mpv-android's
        // proven order. mpv's gpu VO cannot initialize without a window, so a
        // `loadfile` issued before the surface exists just stalls ("connecting"
        // forever) — any load requested meanwhile is queued and fired here.
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                surfaceReady = true
                if (!mpvReady) return
                mpv?.attachSurface(holder.surface)
                mpv?.setOptionString("force-window", "yes")
                val queued = pendingLoad
                if (queued != null) {
                    pendingLoad = null
                    debug("surface ready → loading")
                    doLoad(queued.first, queued.second)
                } else {
                    mpv?.setPropertyString("vo", VIDEO_OUTPUT)
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                surfaceReady = false
                if (!mpvReady) return
                // Drop the VO before the window goes away, else mpv renders
                // into a dead surface.
                mpv?.setPropertyString("vo", "null")
                mpv?.setOptionString("force-window", "no")
                mpv?.detachSurface()
            }
        })
        // Behind the webview; the page's player screen draws no background
        // there, so the video shows through.
        parent.addView(sv, 0)
        wv.setBackgroundColor(Color.TRANSPARENT)
        surfaceView = sv
    }

    /**
     * libass needs a real font file — Android has no fontconfig. mpv looks for
     * `subfont.ttf` in its config dir, so seed it from the system fonts once.
     */
    private fun prepareConfigDir(): File {
        val dir = File(activity.filesDir, "mpv").apply { mkdirs() }
        val subfont = File(dir, "subfont.ttf")
        if (!subfont.exists()) {
            val candidates = listOf(
                "/system/fonts/Roboto-Regular.ttf",
                "/system/fonts/NotoSans-Regular.ttf",
                "/system/fonts/DroidSans.ttf",
            )
            candidates.firstOrNull { File(it).exists() }?.let { src ->
                runCatching { File(src).copyTo(subfont, overwrite = true) }
            }
        }
        return dir
    }

    private fun ensureMpv() {
        if (mpvReady) return
        ensureView()
        mpv = MPVLib.create(activity)
        if (mpv == null) {
            debug("mpv: create failed")
            return
        }

        val configDir = prepareConfigDir()
        mpv?.setOptionString("config", "yes")
        mpv?.setOptionString("config-dir", configDir.path)

        mpv?.setOptionString("vo", VIDEO_OUTPUT)
        mpv?.setOptionString("gpu-context", "android")
        mpv?.setOptionString("opengl-es", "yes")
        // Hardware decode via MediaCodec, copying frames out (the -copy variant)
        // like the iOS build does with VideoToolbox: still GPU decode, but no
        // surface handed between decoder and renderer.
        mpv?.setOptionString("hwdec", "mediacodec-copy")
        mpv?.setOptionString("ao", "audiotrack")
        mpv?.setOptionString("profile", "fast")
        // Phone thermals: skip the expensive gpu-next quality passes.
        mpv?.setOptionString("deband", "no")
        mpv?.setOptionString("scale", "bilinear")
        mpv?.setOptionString("dscale", "bilinear")
        mpv?.setOptionString("cscale", "bilinear")
        mpv?.setOptionString("dither", "no")
        mpv?.setOptionString("hdr-compute-peak", "no")
        mpv?.setOptionString("vd-lavc-threads", "4")
        mpv?.setOptionString("subs-fallback", "yes")
        mpv?.setOptionString("subs-match-os-language", "yes")
        mpv?.setOptionString("cache", "yes")
        mpv?.setOptionString("demuxer-max-bytes", "64MiB")
        mpv?.setOptionString("network-timeout", "10")
        mpv?.setOptionString("keep-open", "yes")
        mpv?.setOptionString("idle", "yes")
        // Debrid resolvers reject library user-agents and redirect across
        // protocols to the final CDN file.
        mpv?.setOptionString(
            "user-agent",
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/124.0.0.0 Mobile Safari/537.36"
        )

        mpv?.init()
        mpvReady = true
        // No window yet — force-window stays off until a surface arrives,
        // otherwise mpv tries to create one and stalls.
        mpv?.setOptionString("force-window", "no")

        surfaceView?.holder?.surface?.takeIf { surfaceReady }?.let {
            mpv?.attachSurface(it)
            mpv?.setOptionString("force-window", "yes")
            mpv?.setPropertyString("vo", VIDEO_OUTPUT)
        }
        // Replay any style the web side pushed before the core existed.
        pendingProps.forEach { (k, v) -> runCatching { mpv?.setPropertyString(k, v) } }
        pendingProps.clear()
        startTicker()
    }

    // MARK: - polling

    private fun startTicker() {
        if (ticker != null) return
        val r = object : Runnable {
            override fun run() {
                if (mpvReady) tick()
                mainHandler.postDelayed(this, 500)
            }
        }
        ticker = r
        mainHandler.postDelayed(r, 500)
    }

    private fun dbl(name: String): Double = runCatching { mpv?.getPropertyDouble(name) }.getOrNull() ?: 0.0
    private fun flag(name: String): Boolean = runCatching { mpv?.getPropertyBoolean(name) }.getOrNull() ?: false
    private fun int(name: String): Int = runCatching { mpv?.getPropertyInt(name) }.getOrNull() ?: 0
    private fun str(name: String): String = runCatching { mpv?.getPropertyString(name) }.getOrNull() ?: ""

    private fun tick() {
        val pos = dbl("time-pos")
        val dur = dbl("duration")
        if (!startedPlaying && (pos > 0 || dur > 0)) {
            startedPlaying = true
            watchdog?.let { mainHandler.removeCallbacks(it) }
            watchdog = null
        }
        val time = JSObject()
        time.put("positionSec", if (pos > 0) pos else 0.0)
        time.put("durationSec", if (dur > 0) dur else 0.0)
        trigger("time", time)

        val paused = flag("pause")
        val idle = flag("core-idle")
        val eof = flag("eof-reached")
        val cache = flag("paused-for-cache")
        val status = when {
            eof && dur > 0 && pos >= dur - 1.0 -> "ended"
            (idle && !paused && !eof) || cache -> "loading"
            paused -> "paused"
            else -> "playing"
        }

        val sig = "${int("track-list/count")}-$status-${int("aid")}-${int("sid")}-${dur.toInt()}"
        if (sig != lastTracksSignature) {
            lastTracksSignature = sig
            emitStatus(status, cache, dur)
        }
        surfaceView?.keepScreenOn = status == "playing" || status == "loading"
    }

    private fun emitStatus(status: String, buffering: Boolean, dur: Double) {
        val data = JSObject()
        data.put("status", status)
        data.put("buffering", buffering)
        data.put("durationSec", if (dur > 0) dur else 0.0)
        data.put("rate", dbl("speed").takeIf { it > 0 } ?: 1.0)
        val audio = JSArray()
        val subs = JSArray()
        val count = int("track-list/count")
        for (i in 0 until count) {
            val type = str("track-list/$i/type")
            if (type != "audio" && type != "sub") continue
            val id = int("track-list/$i/id")
            val title = str("track-list/$i/title")
            val lang = str("track-list/$i/lang")
            val obj = JSObject()
            obj.put("id", id)
            obj.put("label", title.ifEmpty { lang.ifEmpty { "${type.replaceFirstChar { c -> c.uppercase() }} $id" } })
            obj.put("lang", lang)
            obj.put("title", title)
            obj.put("codec", str("track-list/$i/codec"))
            obj.put("selected", flag("track-list/$i/selected"))
            if (type == "audio") audio.put(obj) else subs.put(obj)
        }
        data.put("audioTracks", audio)
        data.put("subtitleTracks", subs)
        data.put("videoWidth", int("width"))
        data.put("videoHeight", int("height"))
        trigger("status", data)
    }

    private fun debug(msg: String) {
        val data = JSObject()
        data.put("msg", msg)
        trigger("debug", data)
    }

    // MARK: - commands

    @Command
    fun probe(invoke: Invoke) {
        val ret = JSObject()
        ret.put("available", true)
        invoke.resolve(ret)
    }

    /** Issue the actual loadfile. Only call once a surface is attached. */
    private fun doLoad(url: String, startAtSec: Double) {
        lastTracksSignature = ""
        if (startAtSec > 0) {
            mpv?.command(arrayOf("loadfile", url, "replace", "start=$startAtSec"))
        } else {
            mpv?.command(arrayOf("loadfile", url, "replace"))
        }
        mpv?.setPropertyBoolean("pause", false)
    }

    @Command
    fun load(invoke: Invoke) {
        val args = invoke.parseArgs(LoadArgs::class.java)
        activity.runOnUiThread {
            debug("load: ${args.url.take(96)}")
            runCatching { ensureMpv() }.onFailure { fail("mpv init threw: ${it.message}") }
            if (!mpvReady) {
                fail("mpv unavailable")
                invoke.resolve()
                return@runOnUiThread
            }
            // Showing the view is what makes Android create the surface; that
            // arrives asynchronously in surfaceCreated. Loading before then
            // leaves mpv waiting for a window forever, so queue it if needed.
            surfaceView?.visibility = View.VISIBLE
            val start = args.startAtSec ?: 0.0
            armWatchdog()
            if (surfaceReady) {
                doLoad(args.url, start)
            } else {
                debug("load: waiting for surface")
                pendingLoad = args.url to start
            }
            invoke.resolve()
        }
    }

    @Command
    fun play(invoke: Invoke) {
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyBoolean("pause", false)
            invoke.resolve()
        }
    }

    @Command
    fun pause(invoke: Invoke) {
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyBoolean("pause", true)
            invoke.resolve()
        }
    }

    @Command
    fun stop(invoke: Invoke) {
        activity.runOnUiThread {
            debug("stop: begin")
            // Drop a queued load, else closing before the surface arrived would
            // start the old stream afterwards.
            pendingLoad = null
            watchdog?.let { mainHandler.removeCallbacks(it) }
            watchdog = null
            if (mpvReady) {
                mpv?.setPropertyBoolean("pause", true)
                mpv?.command(arrayOf("stop"))
            }
            surfaceView?.visibility = View.GONE
            surfaceView?.keepScreenOn = false
            lastTracksSignature = ""
            debug("stop: end")
            invoke.resolve()
        }
    }

    @Command
    fun seek(invoke: Invoke) {
        val args = invoke.parseArgs(SeekArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) mpv?.command(arrayOf("seek", args.sec.toString(), "absolute"))
            invoke.resolve()
        }
    }

    @Command
    fun setVolume(invoke: Invoke) {
        val args = invoke.parseArgs(VolumeArgs::class.java)
        activity.runOnUiThread {
            // JS sends 0..1 (html5 semantics) or 0..100 (mpv semantics).
            val v = if (args.volume <= 1.5) args.volume * 100 else args.volume
            lastVolume = v.toInt().coerceIn(0, 100)
            if (mpvReady) mpv?.setPropertyInt("volume", lastVolume)
            invoke.resolve()
        }
    }

    @Command
    fun setMuted(invoke: Invoke) {
        val args = invoke.parseArgs(MutedArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyBoolean("mute", args.muted)
            invoke.resolve()
        }
    }

    @Command
    fun setRate(invoke: Invoke) {
        val args = invoke.parseArgs(RateArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyDouble("speed", args.rate.coerceIn(0.25, 4.0))
            invoke.resolve()
        }
    }

    @Command
    fun setAudioTrack(invoke: Invoke) {
        val args = invoke.parseArgs(TrackArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyString("aid", if (args.id < 0) "no" else args.id.toString())
            lastTracksSignature = ""
            invoke.resolve()
        }
    }

    @Command
    fun setSubtitleTrack(invoke: Invoke) {
        val args = invoke.parseArgs(TrackArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) mpv?.setPropertyString("sid", if (args.id < 0) "no" else args.id.toString())
            lastTracksSignature = ""
            invoke.resolve()
        }
    }

    @Command
    fun addSubtitle(invoke: Invoke) {
        val args = invoke.parseArgs(SubtitleArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) {
                val mode = if (args.select != false) "select" else "auto"
                mpv?.command(arrayOf("sub-add", args.url, mode))
                lastTracksSignature = ""
            }
            invoke.resolve()
        }
    }

    /**
     * Harbor's subtitle/appearance settings arrive here as mpv property names
     * (sub-color, sub-border-size, sub-scale, sub-ass-override …). With libmpv
     * they are simply forwarded, so the result matches Windows and iOS exactly.
     */
    @Command
    fun setProperty(invoke: Invoke) {
        val args = invoke.parseArgs(SetPropArgs::class.java)
        activity.runOnUiThread {
            if (mpvReady) runCatching { mpv?.setPropertyString(args.name, args.value) }
            else pendingProps[args.name] = args.value
            invoke.resolve()
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
