import AVFoundation
import Cmpv
import ObjectiveC
import Tauri
import UIKit
import WebKit

// Native video playback backed by libmpv (the same engine Harbor uses on the
// desktop). mpv renders into a CAMetalLayer that sits behind the transparent
// webview.
//
// HARD-WON RULES — every "freeze" in this app's history was a violation of
// one of these:
// 1. Never tear down (or reconfigure away) mpv's video output on the
//    user-visible path. One mpv instance is created on first play and reused
//    for the app's lifetime; media changes are `loadfile … replace`, exit is
//    just `pause` + occluding the surface. Anything that destroys the
//    Vulkan/MoltenVK swapchain (mpv `stop`, mpv_terminate_destroy, VLCKit's
//    vout teardown before that) races main-thread CoreAnimation work and
//    deadlocks.
// 2. Never hide the CAMetalLayer (isHidden / removeFromSuperview) while mpv
//    is alive — iOS stops handing drawables to offscreen layers and mpv's
//    render thread starves, wedging the core. Occlude with webview opacity.
// 3. Never resize the layer of a live swapchain while the surface is
//    occluded — the exit rotation would make MoltenVK rebuild the swapchain
//    from the render thread while the main thread holds its own rotation
//    CATransaction on the same (not thread-safe) layer.

struct LoadArgs: Decodable {
  let url: String
  let startAtSec: Double?
}
struct SeekArgs: Decodable { let sec: Double }
struct VolumeArgs: Decodable { let volume: Double }
struct MutedArgs: Decodable { let muted: Bool }
struct RateArgs: Decodable { let rate: Double }
struct TrackArgs: Decodable { let id: Int }
struct SubtitleArgs: Decodable {
  let url: String
  let select: Bool?
}
struct ProbeResponse: Encodable { let available: Bool }
struct ProbeLogArgs: Decodable { let msg: String }
struct SetPropArgs: Decodable {
  let name: String
  let value: String
}

private final class MetalVideoLayer: CAMetalLayer {
  override var drawableSize: CGSize {
    get { super.drawableSize }
    set {
      if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
        super.drawableSize = newValue
      }
    }
  }
}

class NativePlayerPlugin: Plugin {
  // RULE 4 (the pre-halt freeze class): the MAIN thread must NEVER call into
  // mpv. mpv_get/set_property and mpv_command are synchronous with the core;
  // on a stalled demuxer (dead stream link) they block for up to
  // network-timeout seconds — polling state from the main thread wedged it
  // for 30s at a time, which read as a freeze that struck BEFORE the halt
  // could even run. Every mpv interaction lives on this serial queue; the
  // main thread only touches UIKit/CoreAnimation.
  private let mpvQueue = DispatchQueue(label: "app.harbor.mpv", qos: .userInitiated)
  private var mpv: OpaquePointer?
  private var videoView: UIView?
  private var metalLayer: MetalVideoLayer?
  private weak var webview: WKWebView?
  private var pollSource: DispatchSourceTimer?
  private var lastAppliedDrawableSize: CGSize = .zero
  private var pendingStartAt: Double = 0
  private var startApplied = true
  private var lastTracksSignature = ""
  private var ended = false
  private var lastLoadUrl = ""
  private var lastLoadAt: TimeInterval = 0
  // True whenever the webview is opaque (boot, and between a halt and the
  // next file's reveal). Starts true: the webview is only made transparent
  // at the first reveal. Purely bookkeeping — the video view stays visible.
  private var surfaceHidden = true
  // Bumped on every halt AND every load: deferred halt work (pause/occlude)
  // no-ops when a reopen supersedes it.
  private var haltGen = 0
  // Bumped on every orientation change: a deferred rotate-to-portrait from an
  // exit must no-op when a reopen (previous episode!) relocked landscape in
  // the meantime — otherwise the new session ends up displayed in portrait.
  private var orientGen = 0

  // What the app-delegate hook reports as supported orientations. Portrait by
  // default (phone UI); the player flips it to landscape while a video is
  // open. Without this, `requestGeometryUpdate(.portrait)` on exit never
  // sticks — Info.plist allows all orientations, so iOS instantly rotates
  // back to match how the device is physically held, which is why the app
  // used to stay stuck in landscape after leaving the player.
  private static var orientationMask: UIInterfaceOrientationMask = .portrait

  @objc public override func load(webview: WKWebView) {
    self.webview = webview
    // Webview-independent boot marker: lets CI tell "app never came up" from
    // "app is fine but its beacons can't reach the runner".
    NativePlayerPlugin.probe("plugin loaded")
    installOrientationHook()
    // Create the video view + Metal layer NOW (plugin load runs on main):
    // ensureMpv then never needs UIKit, so it can live on mpvQueue. The
    // webview may not be in the hierarchy yet, so retry briefly.
    DispatchQueue.main.async { [weak self] in
      self?.ensureViewRetrying()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // Re-assert landscape only while the player is actually open. (Checking
      // `mpv != nil` here was wrong once the instance became app-lifetime —
      // it forced landscape on the home screen after backgrounding.)
      guard let self = self, NativePlayerPlugin.orientationMask.contains(.landscape) else { return }
      self.applyLandscape()
    }
    NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.layoutMetal()
    }
    // CI-only: replay the freeze sequence natively, no webview involved.
    if let url = ProcessInfo.processInfo.environment["HARBOR_NATIVE_AUTOTEST"], !url.isEmpty {
      nativeAutotest(url: url)
    }
  }

  // MARK: - native autotest (CI freeze reproduction)

  // Drives the exact plugin code paths the phone exercises — lock landscape,
  // load+play, halt, unlock/rotate — entirely from the native side, writing
  // every step plus a main-thread liveness ticker into the probe log. The CI
  // workflow polls that log from outside and samples the process the moment
  // ticks stall. Activated only via HARBOR_NATIVE_AUTOTEST (simctl launch).
  //
  // Crucially it also recreates the phone's OTHER half of the collision: on
  // the device, the exit lands in the middle of the React home-screen render
  // (a storm of WebKit CoreAnimation commits on the main thread). The sim's
  // webview runs no JS, so loadHTMLString drives REAL WebContent renders and
  // UI-process commits at exactly the exit moment.
  private func nativeAutotest(url: String) {
    NativePlayerPlugin.probe("autotest: armed")
    let main = DispatchQueue.main

    func webStorm(_ tag: Int, _ wv: WKWebView?) {
      var rows = ""
      for i in 0..<1500 {
        let hue = (i * 37 + tag * 91) % 360
        rows += "<div style='padding:6px;background:hsl(\(hue),40%,\(20 + i % 30)%);color:#dde'>row \(i) — storm \(tag) lorem ipsum dolor sit amet</div>"
      }
      let html = "<html><body style='margin:0;background:#0b0e14'>\(rows)</body></html>"
      wv?.loadHTMLString(html, baseURL: nil)
    }

    func openSession(at t: Double, tag: Int) {
      main.asyncAfter(deadline: .now() + t) { [weak self] in
        guard let self = self else { return }
        NativePlayerPlugin.probe("autotest: open \(tag)")
        NativePlayerPlugin.orientationMask = .landscape
        self.applyLandscape()
        // Mirror the real load(): mpv work on mpvQueue, UI on main.
        self.mpvQueue.async { [weak self] in
          guard let self = self else { return }
          try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
          try? AVAudioSession.sharedInstance().setActive(true)
          self.ensureMpv()
          self.startPolling()
          self.haltGen += 1
          self.command(["loadfile", url, "replace"])
          self.setProp("pause", flag: false)
          self.setProp("mute", flag: false)
        }
      }
    }

    func exitSession(at t: Double, tag: Int) {
      main.asyncAfter(deadline: .now() + t) { [weak self] in
        guard let self = self else { return }
        // The unmount render storm (main/WebKit) and the halt (mpvQueue) land
        // in the same breath, exactly like the real exit.
        webStorm(tag, self.webview)
        self.mpvQueue.async { [weak self] in
          guard let self = self else { return }
          NativePlayerPlugin.probe(String(format: "autotest: exit %d pos=%.2f", tag, self.getDouble("time-pos")))
          self.haltPlayback()
          NativePlayerPlugin.probe("autotest: halt \(tag) returned")
        }
        NativePlayerPlugin.orientationMask = .portrait
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          NativePlayerPlugin.probe("autotest: portrait \(tag)")
          if #available(iOS 16.0, *) {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            self?.webview?.window?.rootViewController?
              .setNeedsUpdateOfSupportedInterfaceOrientations()
          }
        }
      }
    }

    // Cycle plan: exits at different playback phases — mid-load, just as
    // playback starts, and well into playback (the episode-change case).
    openSession(at: 3.0, tag: 1)
    exitSession(at: 12.0, tag: 1)   // ~8s in: playing
    openSession(at: 15.0, tag: 2)
    exitSession(at: 16.2, tag: 2)   // ~1.2s in: still opening/loading
    openSession(at: 19.0, tag: 3)
    exitSession(at: 24.0, tag: 3)   // ~5s in: early playback
    openSession(at: 27.0, tag: 4)
    exitSession(at: 36.0, tag: 4)   // ~9s in: settled playback
    // Playback health probes for cycle 1 (proves real decode in the sim).
    for t in [8.0, 10.0] {
      mpvQueue.asyncAfter(deadline: .now() + t) { [weak self] in
        guard let self = self else { return }
        NativePlayerPlugin.probe(String(format: "autotest: pos=%.2f", self.getDouble("time-pos")))
      }
    }
    // Continuous liveness ticker across all cycles.
    var t = 3.5
    while t <= 44.0 {
      let at = t
      main.asyncAfter(deadline: .now() + at) {
        NativePlayerPlugin.probe(String(format: "alive +%.1fs", at))
      }
      t += 0.5
    }
    main.asyncAfter(deadline: .now() + 45.0) {
      NativePlayerPlugin.probe("autotest: SURVIVED")
    }
  }

  // Tauri's generated AppDelegate does not implement
  // application(_:supportedInterfaceOrientationsFor:), so orientation control
  // falls through to Info.plist (all orientations) and cannot be changed at
  // runtime. Add the method dynamically; it consults our mask, which makes
  // lock-landscape / restore-portrait actually stick.
  private func installOrientationHook() {
    guard let delegate = UIApplication.shared.delegate else { return }
    let cls: AnyClass = type(of: delegate)
    let sel = NSSelectorFromString("application:supportedInterfaceOrientationsForWindow:")
    guard class_getInstanceMethod(cls, sel) == nil else { return }
    let block: @convention(block) (AnyObject, UIApplication, UIWindow?) -> UInt = { _, _, _ in
      NativePlayerPlugin.orientationMask.rawValue
    }
    class_addMethod(cls, sel, imp_implementationWithBlock(block), "Q@:@@")
  }

  // MARK: - view / mpv setup

  // Main thread only. Retries until the webview has a superview to sit under.
  private func ensureViewRetrying(_ attempts: Int = 0) {
    ensureView()
    if videoView == nil, attempts < 60 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.ensureViewRetrying(attempts + 1)
      }
    }
  }

  private func ensureView() {
    guard videoView == nil, let webview = self.webview, let superview = webview.superview else {
      return
    }
    // FIXED LANDSCAPE GEOMETRY, decided once: the player is landscape-only,
    // and mpv's VO learns its surface size at init — wid embedding has no
    // resize channel, so a size chosen while the app is still portrait (the
    // eager creation runs at launch) would stick forever and render the
    // video into the bottom-left corner. Landscape dimensions are the same
    // regardless of current orientation via max/min.
    let screen = UIScreen.main.bounds
    let w = max(screen.width, screen.height)
    let h = min(screen.width, screen.height)
    let scale = UIScreen.main.nativeScale
    let view = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
    view.autoresizingMask = []
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false

    let layer = MetalVideoLayer()
    layer.contentsGravity = .resizeAspect
    layer.contentsScale = scale
    layer.framebufferOnly = true
    layer.backgroundColor = UIColor.black.cgColor
    layer.anchorPoint = .zero
    layer.position = .zero
    layer.frame = view.bounds
    layer.drawableSize = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    lastAppliedDrawableSize = layer.drawableSize
    view.layer.addSublayer(layer)

    // The webview stays OPAQUE here — it only goes transparent at the first
    // reveal (showVideo), so nothing of this surface shows through at boot.
    superview.insertSubview(view, belowSubview: webview)

    self.videoView = view
    self.metalLayer = layer
  }

  private func layoutMetal() {
    guard let view = videoView, let layer = metalLayer else { return }
    // While occluded the geometry doesn't matter and the layer must not be
    // touched (resizing a live swapchain vs. main-thread CA was an early
    // freeze); showVideo() re-runs this once the surface is visible again.
    guard !surfaceHidden else { return }
    // Re-assert the fixed landscape geometry (idempotent; the values never
    // change by design).
    let screen = UIScreen.main.bounds
    let w = max(screen.width, screen.height)
    let h = min(screen.width, screen.height)
    let frame = CGRect(x: 0, y: 0, width: w, height: h)
    let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
    let drawable = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.frame = frame
    layer.contentsScale = scale
    layer.frame = frame
    if drawable != lastAppliedDrawableSize {
      layer.drawableSize = drawable
      lastAppliedDrawableSize = drawable
    }
    CATransaction.commit()
  }

  // mpvQueue only. The view/layer were created eagerly at plugin load.
  private func ensureMpv() {
    guard mpv == nil else { return }
    guard let layer = metalLayer else {
      NativePlayerPlugin.probe("ensureMpv: metal layer not ready")
      return
    }

    let ctx = mpv_create()
    guard let ctx = ctx else { return }
    mpv = ctx

    // "fast" profile FIRST, as the baseline every later option overrides. Beyond
    // what we already set manually it turns off gpu-next's correct-downscaling,
    // linear-downscaling and sigmoid-upscaling — real per-frame GPU shader cost
    // on every 4K→screen scale, and a major share of the phone-heat complaint.
    setOpt("profile", "fast")

    var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    mpv_set_option(ctx, "wid", MPV_FORMAT_INT64, &wid)
    setOpt("vo", "gpu-next")
    setOpt("gpu-api", "vulkan")
    setOpt("gpu-context", "moltenvk")
    // videotoolbox-COPY, not zero-copy: still hardware decode, but frames are
    // copied out of VideoToolbox instead of shared as IOSurfaces. Zero-copy
    // IOSurfaces are locked by BOTH mpv's render thread (Vulkan/Metal import)
    // and the system compositor — the same compositor processing the exit's
    // CoreAnimation commits. Exits from PLAYING (VT frames actively cycling)
    // froze the main thread inside that commit; exits from PAUSED (no frames
    // in flight) never did, and the simulator (no VT at all) could not
    // reproduce it. The copy costs ~one memcpy per frame.
    setOpt("hwdec", "videotoolbox-copy")
    setOpt("ao", "audiounit")
    setOpt("audio-channels", "auto")
    setOpt("audio-fallback-to-null", "yes")
    // fifo (vsync), NOT immediate: immediate presents as fast as the GPU can
    // render — uncapped frame rate keeps the GPU pinned and the phone runs
    // hot. fifo caps at the display refresh. (immediate was an early attempt
    // at the exit freeze; the real fixes were hwdec=videotoolbox-copy and
    // moving all mpv calls off the main thread, so vsync is safe now.)
    setOpt("vulkan-swap-mode", "fifo")
    // Phone thermal budget: turn OFF the expensive gpu-next quality features
    // that are pointless on a 6-inch screen and are the main GPU heat source.
    setOpt("deband", "no")            // debanding shader is costly
    setOpt("scale", "bilinear")       // cheap upscaler (vs. the default)
    setOpt("dscale", "bilinear")      // cheap downscaler (matters for 4K->1080)
    setOpt("cscale", "bilinear")
    setOpt("dither", "no")
    setOpt("hdr-compute-peak", "no")  // avoid per-frame HDR peak analysis
    setOpt("interpolation", "no")     // never motion-interpolate on the phone
    // Cap software-decode threads. hwdec covers the normal case, but content
    // VideoToolbox can't do (AV1 on pre-A17, some 10-bit profiles) falls back
    // to ffmpeg software decode, where "0" (auto) spawns core-count threads
    // and turns the phone into a hand warmer. Four is enough for 1080p SW
    // decode and bounds the worst case.
    setOpt("vd-lavc-threads", "4")
    setOpt("video-rotate", "no")
    setOpt("keep-open", "yes")
    setOpt("subs-fallback", "yes")
    setOpt("subs-match-os-language", "yes")
    setOpt("cache", "yes")
    setOpt("demuxer-max-bytes", "64MiB")
    // 10s, not 30: a dead link should fail fast into the JS eject/retry flow
    // — and it bounds how long a stalled core can delay queued work.
    setOpt("network-timeout", "10")
    // The instance is reused for the app's lifetime. idle=yes keeps the core
    // alive if the playlist ever empties (a failed load, etc.) instead of
    // shutting down — a dead handle would break every later open.
    setOpt("idle", "yes")
    // CI only: surface mpv warnings/errors into the probe log. Kept off on
    // devices — it changes mpv's event traffic, and the device build must
    // stay byte-for-byte on the user-confirmed-good behavior.
    if ProcessInfo.processInfo.environment["HARBOR_NATIVE_AUTOTEST"] != nil {
      mpv_request_log_messages(ctx, "warn")
    }
    mpv_initialize(ctx)
  }

  // mpvQueue only (start/stop are called from mpvQueue contexts). The tick
  // runs entirely off-main: property reads on a stalled demuxer may block for
  // seconds, and that must never touch the UI thread.
  private func startPolling() {
    guard pollSource == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: mpvQueue)
    // 0.5s, was 0.25s: every tick ends in a Tauri event → evaluateJavaScript →
    // a WebContent wake-up + React state update. Halving the rate halves that
    // steady CPU drip for the whole session (thermal complaint); the seekbar
    // still updates twice a second, and seeks reflect optimistically in JS.
    // Generous leeway lets the kernel coalesce the timer with other wake-ups.
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    pollSource = timer
  }

  private func stopPolling() {
    pollSource?.cancel()
    pollSource = nil
  }

  private func setOpt(_ name: String, _ value: String) {
    guard let mpv = mpv else { return }
    mpv_set_option_string(mpv, name, value)
  }

  // MARK: - polling / events

  private func tick() {
    guard let mpv = mpv else { return }
    // Drain mpv's event queue so it does not back up (we poll state below).
    while true {
      guard let ev = mpv_wait_event(mpv, 0) else { break }
      if ev.pointee.event_id == MPV_EVENT_NONE { break }
      if ev.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
      if ev.pointee.event_id == MPV_EVENT_START_FILE {
        debug("mpv: start-file")
      }
      // After a halt the surface is occluded; reveal once the NEW file is
      // open (not on `duration > 0` alone — that could still read the
      // previous file during a `loadfile … replace`).
      if ev.pointee.event_id == MPV_EVENT_FILE_LOADED {
        debug("mpv: file loaded")
        if surfaceHidden {
          surfaceHidden = false
          DispatchQueue.main.async { [weak self] in self?.showVideo() }
        }
        // Track titles/langs can settle after FILE_LOADED — force a couple of
        // re-emits so the menus don't keep placeholder labels.
        for d in [1.5, 4.0] {
          mpvQueue.asyncAfter(deadline: .now() + d) { [weak self] in
            self?.lastTracksSignature = ""
          }
        }
      }
      // A failed open (dead link, network error) otherwise leaves the UI on a
      // silent infinite spinner — surface it so the JS side can eject and
      // retry immediately, and so the exit log names the actual error.
      if ev.pointee.event_id == MPV_EVENT_END_FILE, let raw = ev.pointee.data {
        let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if end.reason == MPV_END_FILE_REASON_ERROR {
          let err = String(cString: mpv_error_string(end.error))
          NativePlayerPlugin.probe("mpv end-file error: \(err)")
          debug("mpv: end-file error \(err)")
          var data: JSObject = [:]
          data["status"] = "error"
          trigger("status", data: data)
        }
      }
      // mpv warnings/errors → probe log (requested at "warn" level, so this
      // stays quiet unless something is actually wrong).
      if ev.pointee.event_id == MPV_EVENT_LOG_MESSAGE, let raw = ev.pointee.data {
        let log = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
        let prefix = log.prefix.map { String(cString: $0) } ?? "?"
        let text = log.text.map { String(cString: $0).trimmingCharacters(in: .newlines) } ?? ""
        if !text.isEmpty {
          NativePlayerPlugin.probe("mpv[\(prefix)] \(String(text.prefix(160)))")
        }
      }
    }
    // (No layoutMetal here: layer geometry is pure UI, handled on main by the
    // orientation observer and showVideo. This tick must stay UIKit-free.)

    let pos = getDouble("time-pos")
    let dur = getDouble("duration")
    // Belt-and-braces reveal: if the FILE_LOADED event was somehow missed,
    // a loaded file (the old one is unloaded the moment `replace` starts, so
    // a duration can only come from the new file) still un-occludes the UI.
    if surfaceHidden, dur > 0 {
      debug("tick: reveal via duration")
      surfaceHidden = false
      DispatchQueue.main.async { [weak self] in self?.showVideo() }
    }
    let paused = getFlag("pause")
    let idle = getFlag("core-idle")
    let eof = getFlag("eof-reached")
    let cache = getFlag("paused-for-cache")
    let seeking = getFlag("seeking")

    var timeData: JSObject = [:]
    timeData["positionSec"] = max(pos, 0)
    timeData["durationSec"] = max(dur, 0)
    trigger("time", data: timeData)

    let loading = (idle && !paused && !eof) || cache || seeking
    let status: String
    if eof && dur > 0 && pos >= dur - 1.0 {
      status = "ended"
    } else if loading {
      status = "loading"
    } else if paused {
      status = "paused"
    } else {
      status = "playing"
    }

    if !startApplied, pendingStartAt > 0, dur > 0 {
      startApplied = true
      seekAbsolute(pendingStartAt)
    }

    // Include the selected track ids so selection changes propagate, and the
    // first sub's lang so late-arriving track metadata triggers a re-emit.
    let sig = "\(getInt("track-list/count"))-\(status)-\(getInt("aid"))-\(getInt("sid"))-\(getString("track-list/2/lang") ?? "")"
    if sig != lastTracksSignature {
      lastTracksSignature = sig
      emitStatus(status: status, buffering: cache, dur: dur)
    }
  }

  private func emitStatus(status: String, buffering: Bool, dur: Double) {
    var data: JSObject = [:]
    data["status"] = status
    data["buffering"] = buffering
    data["durationSec"] = max(dur, 0)
    data["rate"] = getDouble("speed")
    let (audio, subs) = trackLists()
    data["audioTracks"] = audio
    data["subtitleTracks"] = subs
    data["videoWidth"] = getInt("width")
    data["videoHeight"] = getInt("height")
    trigger("status", data: data)
  }

  private func trackLists() -> ([JSObject], [JSObject]) {
    var audio: [JSObject] = []
    var subs: [JSObject] = []
    let count = getInt("track-list/count")
    guard count > 0 else { return (audio, subs) }
    for i in 0..<count {
      let type = getString("track-list/\(i)/type") ?? ""
      let id = getInt("track-list/\(i)/id")
      let title = getString("track-list/\(i)/title") ?? ""
      let lang = getString("track-list/\(i)/lang") ?? ""
      let codec = getString("track-list/\(i)/codec") ?? ""
      let selected = getFlag("track-list/\(i)/selected")
      let label = !title.isEmpty ? title : (!lang.isEmpty ? lang : "\(type.capitalized) \(id)")
      var obj: JSObject = [:]
      obj["id"] = id
      obj["label"] = label
      // The subtitle/audio menus group by `lang` and show `title` — without
      // them every track rendered as "Embedded track · UNKNOWN".
      obj["lang"] = lang
      obj["title"] = title
      obj["codec"] = codec
      obj["selected"] = selected
      if type == "audio" { audio.append(obj) } else if type == "sub" { subs.append(obj) }
    }
    return (audio, subs)
  }

  // MARK: - commands

  // Diagnostic breadcrumb, surfaced on the JS side's persisted exit log.
  // NOTE: delivery needs BOTH the native main thread (evaluateJavaScript) and
  // a live WebContent process — if either hangs, the line never lands.
  private func debug(_ msg: String) {
    var data: JSObject = [:]
    data["msg"] = msg
    trigger("debug", data: data)
  }

  // Webview-independent breadcrumb: appended to a plain file in Documents so
  // it survives a freeze/force-quit even when the WebContent process (which
  // writes the JS exit log) is the thing that hung. Read back by exitProbe on
  // the next launch; CI polls the file live from outside the simulator.
  //
  // NOT UserDefaults: every UserDefaults write+synchronize is a synchronous
  // XPC round-trip to cfprefsd, and at heartbeat frequency that daemon backs
  // up until each probe blocks the main thread for seconds — the observation
  // itself manufactured a fake freeze in CI. A file append costs microseconds.
  private static let probeEpoch = Date()
  private static let probeLock = NSLock()
  private static let probeURL: URL = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("probe.log")
  }()
  // Callable from any thread (main, mpvQueue, autotest timers).
  static func probe(_ msg: String) {
    let t = Date().timeIntervalSince(probeEpoch)
    guard let data = String(format: "%.2f  %@\n", t, msg).data(using: .utf8) else { return }
    probeLock.lock()
    defer { probeLock.unlock() }
    if let handle = try? FileHandle(forWritingTo: probeURL) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(data)
    } else {
      try? data.write(to: probeURL)
    }
  }

  @objc public func exitProbe(_ invoke: Invoke) {
    let text = (try? String(contentsOf: NativePlayerPlugin.probeURL, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: NativePlayerPlugin.probeURL)
    var data: JSObject = [:]
    data["text"] = text
    invoke.resolve(data)
  }

  // Resolves via a main-queue hop: the returned promise settles only if the
  // native MAIN thread is alive. The CI autotest pings this to detect the
  // exact moment the main thread wedges.
  @objc public func mainPing(_ invoke: Invoke) {
    DispatchQueue.main.async { invoke.resolve() }
  }

  // JS-side breadcrumb into the webview-independent UserDefaults log — a
  // beacon channel that needs no network at all; CI dumps it post-mortem.
  @objc public func probeLog(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(ProbeLogArgs.self)
    NativePlayerPlugin.probe("js: \(args.msg)")
    invoke.resolve()
  }

  @objc public func probe(_ invoke: Invoke) {
    invoke.resolve(ProbeResponse(available: true))
  }

  @objc public func load(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(LoadArgs.self)
    mpvQueue.async { [weak self] in
      guard let self = self else { invoke.resolve(); return }
      NativePlayerPlugin.probe("load begin")
      self.debug("load: begin")
      // De-dupe racing loads. React can fire two loads in the same instant
      // (fast remount / a URL-variant swap); two `loadfile replace` racing
      // through mpv destabilized exactly the sessions that later froze on
      // exit. Same URL within 1.5s or ANY second load within 0.4s: the first
      // wins, the duplicate is a no-op (no user flow reopens that fast).
      let now = Date().timeIntervalSince1970
      if now - self.lastLoadAt < (args.url == self.lastLoadUrl ? 1.5 : 0.4), self.lastLoadAt > 0 {
        self.debug("load: dup ignored")
        self.setProp("pause", flag: false)
        invoke.resolve()
        return
      }
      self.lastLoadUrl = args.url
      self.lastLoadAt = now
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try? AVAudioSession.sharedInstance().setActive(true)
      self.ensureMpv()
      // A prior halt hid the video view; tick() re-shows it on the NEW file's
      // MPV_EVENT_FILE_LOADED — showing it here would flash the previous
      // video's last frame while this one is still opening.
      self.startPolling()
      // Cancel any deferred halt work (pause/occlude) from a previous exit.
      self.haltGen += 1
      DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
      self.debug("load: mpv ready")
      self.pendingStartAt = args.startAtSec ?? 0
      self.startApplied = self.pendingStartAt <= 0
      self.lastTracksSignature = ""
      self.ended = false
      // `replace` swaps media in-place — no teardown, so next/prev episode is
      // just another loadfile with nothing to free.
      self.command(["loadfile", args.url, "replace"])
      self.debug("load: loadfile sent")
      self.setProp("pause", flag: false)
      // Undo the halt's mute; the JS side re-applies its own audio state.
      self.setProp("mute", flag: false)
      invoke.resolve()
    }
  }

  @objc public func play(_ invoke: Invoke) {
    mpvQueue.async { [weak self] in
      self?.setProp("pause", flag: false)
      invoke.resolve()
    }
  }

  @objc public func pause(_ invoke: Invoke) {
    mpvQueue.async { [weak self] in
      self?.setProp("pause", flag: true)
      invoke.resolve()
    }
  }

  @objc public func stop(_ invoke: Invoke) {
    mpvQueue.async { [weak self] in
      NativePlayerPlugin.probe("halt begin")
      self?.debug("stop: halt begin")
      self?.haltPlayback()
      self?.debug("stop: halt end")
      NativePlayerPlugin.probe("halt end")
      invoke.resolve()
      // Liveness ticker across the freeze window, independent of the webview:
      // scheduled on MAIN on purpose — its whole point is proving the main
      // thread is alive.
      for d in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
          NativePlayerPlugin.probe(String(format: "main alive +%.1fs", d))
        }
      }
    }
  }

  @objc public func seek(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SeekArgs.self)
    mpvQueue.async { [weak self] in
      self?.seekAbsolute(args.sec)
      invoke.resolve()
    }
  }

  @objc public func setVolume(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(VolumeArgs.self)
    mpvQueue.async { [weak self] in
      self?.setProp("volume", double: max(0, min(1, args.volume)) * 100)
      invoke.resolve()
    }
  }

  @objc public func setMuted(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(MutedArgs.self)
    mpvQueue.async { [weak self] in
      self?.setProp("mute", flag: args.muted)
      invoke.resolve()
    }
  }

  @objc public func setRate(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(RateArgs.self)
    mpvQueue.async { [weak self] in
      self?.setProp("speed", double: args.rate)
      invoke.resolve()
    }
  }

  @objc public func setAudioTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    mpvQueue.async { [weak self] in
      self?.setProp("aid", int: Int64(args.id))
      invoke.resolve()
    }
  }

  @objc public func setSubtitleTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    mpvQueue.async { [weak self] in
      if args.id < 0 {
        self?.setPropString("sid", "no")
      } else {
        self?.setProp("sid", int: Int64(args.id))
      }
      invoke.resolve()
    }
  }

  @objc public func addSubtitle(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SubtitleArgs.self)
    mpvQueue.async { [weak self] in
      self?.command(["sub-add", args.url, (args.select ?? true) ? "select" : "auto"])
      invoke.resolve()
    }
  }

  // Generic mpv property setter, used by the JS sub-style code so subtitle
  // appearance (font size/color/border, sub-ass-override=force, margins, …)
  // works on iOS exactly like desktop. Any mpv property settable as a string.
  @objc public func setProperty(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SetPropArgs.self)
    mpvQueue.async { [weak self] in
      self?.setPropString(args.name, args.value)
      invoke.resolve()
    }
  }

  @objc public func lockLandscape(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      NativePlayerPlugin.probe("lock landscape")
      self?.applyLandscape()
      invoke.resolve()
    }
  }

  @objc public func unlockOrientation(_ invoke: Invoke) {
    invoke.resolve()
    // Constrain to portrait right away (any orientation query from here on
    // sees it — set on main, the mask is read by UIKit from main), but
    // trigger the actual rotation a beat later, once the player unmount and
    // the home screen's first render are past. The generation guard voids
    // the deferred rotation when a reopen (previous episode) relocks
    // landscape within that window — otherwise the stale portrait request
    // landed INSIDE the new session and left the player displayed sideways.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.orientGen += 1
      let gen = self.orientGen
      NativePlayerPlugin.orientationMask = .portrait
      NativePlayerPlugin.probe("unlock: mask -> portrait")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self = self, self.orientGen == gen else {
          NativePlayerPlugin.probe("orient: stale portrait apply skipped")
          return
        }
        NativePlayerPlugin.probe("orient: apply begin")
        self.debug("orient: portrait apply")
        if #available(iOS 16.0, *) {
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
          scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
          self.webview?.window?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
          UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        NativePlayerPlugin.probe("orient: apply end")
      }
    }
  }

  private func applyLandscape() {
    orientGen += 1
    // A landscape lock means a player is (re)opening — on an episode switch it
    // arrives BEFORE the new load, in the same instant a previous exit's
    // deferred pause/occlude is still pending. Bump haltGen so that pending
    // work no-ops instead of pausing or blacking out the fresh session. This
    // was the "previous episode" bug: the deferred occlude fired 1ms before
    // the reopen's load and left the new episode's surface occluded.
    // (surfaceHidden stays as-is: if occlude already ran, it's still true and
    // the reopen's FILE_LOADED -> showVideo un-occludes the webview.
    // haltGen is mpvQueue-confined, so hop.)
    mpvQueue.async { [weak self] in self?.haltGen += 1 }
    NativePlayerPlugin.orientationMask = .landscape
    if #available(iOS 16.0, *) {
      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
      scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
      webview?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
    }
  }

  // MARK: - halt (normal exit) vs. teardown (app shutdown)

  // The normal player-exit path. It does NOT destroy mpv, its Metal layer or
  // the poll timer — those are created once and reused for the app's lifetime.
  //
  // Creating/destroying mpv on every open/close was the whole freeze saga:
  // mpv_terminate_destroy drains decode/network threads (up to network-timeout
  // seconds) and its render thread keeps touching the CAMetalLayer. Destroying
  // it while the next player spun up meant two MoltenVK/Vulkan contexts fought
  // over the GPU, which wedged the main thread (CATransaction/drawable) so the
  // very next `stop` never even ran — exactly what the exit log showed
  // (…"bridge cleanup: done" then nothing). Reusing one instance makes exit
  // instant and destroys nothing; the next open is just another loadfile.
  // mpvQueue only.
  private func haltPlayback() {
    DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    lastLoadUrl = ""
    lastLoadAt = 0
    stopPolling()
    haltGen += 1
    let gen = haltGen
    // NEVER `stop` (unloading destroys the video output — swapchain teardown,
    // rule 1). PAUSE IN THIS TURN: decode and rendering must stop NOW. The
    // mute-only experiment (keep playing invisibly, pause 0.7s later) froze
    // EVERY exit on the phone — even from an already-paused state exits died
    // — proving an actively presenting render thread during the exit render
    // storm is the poison, while the user-confirmed-good build always paused
    // here. Mute too, so the next load starts silent until JS applies state.
    // (Both are safe here: this runs on mpvQueue, never on main.)
    setProp("pause", flag: true)
    setProp("mute", flag: true)
    surfaceHidden = true
    // The webview opacity flip is UI work and commits on MAIN 0.8s later,
    // once mpv is provably idle and the unmount storm has passed. The gen
    // check re-runs on mpvQueue so a reopen reliably cancels it.
    mpvQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self = self, self.haltGen == gen, self.surfaceHidden else { return }
      NativePlayerPlugin.probe("halt: deferred occlude")
      DispatchQueue.main.async { [weak self] in self?.hideVideo() }
    }
  }

  // Reveal the native video surface by making the webview transparent again.
  private func showVideo() {
    surfaceHidden = false
    guard let webview = self.webview else { return }
    webview.isOpaque = false
    webview.backgroundColor = .clear
    webview.scrollView.backgroundColor = .clear
    layoutMetal()
  }

  // Occlude the video by painting the webview opaque black. The videoView
  // itself is NEVER hidden (isHidden/removeFromSuperview): iOS stops handing
  // drawables to an offscreen CAMetalLayer, and mpv's still-alive render
  // thread would starve on nextDrawable — wedging the core so the next
  // loadfile never opens. The opaque webview fully covers it anyway.
  private func hideVideo() {
    surfaceHidden = true
    guard let webview = self.webview else { return }
    webview.isOpaque = true
    webview.backgroundColor = .black
    webview.scrollView.backgroundColor = .black
  }

  // (No teardown function on purpose: the mpv instance is app-lifetime by
  // design — see rule 1. iOS reclaims everything at process exit.)

  // MARK: - mpv helpers

  // All writes are ASYNC (fire-and-forget): the sync variants wait for the
  // core, and a core wedged on a dead network stream (or dead sockets after
  // backgrounding) would jam the whole mpvQueue behind it — the halt for the
  // next exit then never ran, which read as a frozen player. The async
  // variants copy their arguments and return immediately; replies arrive as
  // (ignored) COMMAND_REPLY/SET_PROPERTY_REPLY events in the tick drain.
  private func command(_ args: [String]) {
    guard let mpv = mpv else { return }
    // strdup gives mutable copies we own and must free; mpv wants a
    // NULL-terminated `const char **`, so hand it UnsafePointer views.
    let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    defer { for p in owned where p != nil { free(p) } }
    var cargs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
    cargs.append(nil)
    cargs.withUnsafeMutableBufferPointer { buf in
      _ = mpv_command_async(mpv, 0, buf.baseAddress)
    }
  }

  private func seekAbsolute(_ sec: Double) {
    command(["seek", String(format: "%.3f", sec), "absolute"])
  }

  private func setProp(_ name: String, flag: Bool) {
    guard let mpv = mpv else { return }
    var v: Int32 = flag ? 1 : 0
    _ = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &v)
  }
  private func setProp(_ name: String, double: Double) {
    guard let mpv = mpv else { return }
    var v = double
    _ = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &v)
  }
  private func setProp(_ name: String, int: Int64) {
    guard let mpv = mpv else { return }
    var v = int
    _ = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &v)
  }
  private func setPropString(_ name: String, _ value: String) {
    guard let mpv = mpv else { return }
    value.withCString { cstr in
      var ptr: UnsafePointer<CChar>? = cstr
      _ = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_STRING, &ptr)
    }
  }

  private func getDouble(_ name: String) -> Double {
    guard let mpv = mpv else { return 0 }
    var v = Double()
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    return v
  }
  private func getInt(_ name: String) -> Int {
    guard let mpv = mpv else { return 0 }
    var v = Int64()
    mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v)
    return Int(v)
  }
  private func getFlag(_ name: String) -> Bool {
    guard let mpv = mpv else { return false }
    var v = Int64()
    mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v)
    return v > 0
  }
  private func getString(_ name: String) -> String? {
    guard let mpv = mpv else { return nil }
    guard let c = mpv_get_property_string(mpv, name) else { return nil }
    let s = String(cString: c)
    mpv_free(c)
    return s
  }
}

@_cdecl("init_plugin_native_player")
func initPlugin() -> Plugin {
  return NativePlayerPlugin()
}
