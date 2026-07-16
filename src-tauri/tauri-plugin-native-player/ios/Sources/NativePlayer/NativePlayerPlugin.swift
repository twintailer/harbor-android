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
  private var mpv: OpaquePointer?
  private var videoView: UIView?
  private var metalLayer: MetalVideoLayer?
  private weak var webview: WKWebView?
  private var pollTimer: Timer?
  private var lastAppliedDrawableSize: CGSize = .zero
  private var pendingStartAt: Double = 0
  private var startApplied = true
  private var lastTracksSignature = ""
  private var ended = false
  private var lastLoadUrl = ""
  private var lastLoadAt: TimeInterval = 0
  // True between a halt (player closed, webview opaque) and the reveal of the
  // next file. Purely bookkeeping — the video view itself stays visible.
  private var surfaceHidden = false
  // Bumped on every halt AND every load: deferred halt work (pause/occlude)
  // no-ops when a reopen supersedes it.
  private var haltGen = 0

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
  // load+play, halt while PLAYING (the episode-change case), unlock/rotate —
  // entirely from the native side, writing every step plus a main-thread
  // liveness ticker into the UserDefaults probe log. The CI workflow polls
  // that log from outside and samples the process the moment ticks stall.
  // Activated only via the HARBOR_NATIVE_AUTOTEST env var (simctl launch).
  private func nativeAutotest(url: String) {
    NativePlayerPlugin.probe("autotest: armed")
    let main = DispatchQueue.main
    main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      NativePlayerPlugin.probe("autotest: lock landscape")
      self?.applyLandscape()
    }
    main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
      guard let self = self else { return }
      NativePlayerPlugin.probe("autotest: load")
      self.ensureMpv()
      self.startPolling()
      self.command(["loadfile", url, "replace"])
      self.setProp("pause", flag: false)
      NativePlayerPlugin.probe("autotest: loadfile sent")
    }
    // Playback health checks — proves mpv actually decodes in the simulator.
    for t in [8.0, 10.0, 12.0] {
      main.asyncAfter(deadline: .now() + t) { [weak self] in
        guard let self = self else { return }
        NativePlayerPlugin.probe(String(format: "autotest: pos=%.2f", self.getDouble("time-pos")))
      }
    }
    // Exit while PLAYING — the phone's failing case (episode change).
    main.asyncAfter(deadline: .now() + 13.0) { [weak self] in
      NativePlayerPlugin.probe("autotest: halt (from playing)")
      self?.haltPlayback()
      NativePlayerPlugin.probe("autotest: halt returned")
      // Mirror the JS exit: unlock/rotate right after.
      NativePlayerPlugin.orientationMask = .portrait
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        NativePlayerPlugin.probe("autotest: portrait apply")
        if #available(iOS 16.0, *) {
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
          scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
          self?.webview?.window?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        NativePlayerPlugin.probe("autotest: portrait applied")
      }
    }
    // Liveness ticker across the freeze window.
    var t = 13.5
    while t <= 22.0 {
      let at = t
      main.asyncAfter(deadline: .now() + at) {
        NativePlayerPlugin.probe(String(format: "alive +%.1fs", at))
      }
      t += 0.5
    }
    // Re-open (second session), then a second halt — the full cycle.
    main.asyncAfter(deadline: .now() + 23.0) { [weak self] in
      guard let self = self else { return }
      NativePlayerPlugin.probe("autotest: reopen")
      NativePlayerPlugin.orientationMask = .landscape
      self.applyLandscape()
      self.startPolling()
      self.haltGen += 1
      self.command(["loadfile", url, "replace"])
      self.setProp("pause", flag: false)
      self.setProp("mute", flag: false)
    }
    main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
      NativePlayerPlugin.probe("autotest: halt 2 (from playing)")
      self?.haltPlayback()
      NativePlayerPlugin.probe("autotest: halt 2 returned")
    }
    var t2 = 30.5
    while t2 <= 38.0 {
      let at = t2
      main.asyncAfter(deadline: .now() + at) {
        NativePlayerPlugin.probe(String(format: "alive2 +%.1fs", at))
      }
      t2 += 0.5
    }
    main.asyncAfter(deadline: .now() + 39.0) {
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

  private func ensureView() {
    guard videoView == nil, let webview = self.webview, let superview = webview.superview else {
      return
    }
    let view = UIView(frame: superview.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false

    let layer = MetalVideoLayer()
    layer.contentsGravity = .resizeAspect
    layer.contentsScale = UIScreen.main.nativeScale
    layer.framebufferOnly = true
    layer.backgroundColor = UIColor.black.cgColor
    layer.anchorPoint = .zero
    layer.position = .zero
    view.layer.addSublayer(layer)

    superview.insertSubview(view, belowSubview: webview)
    webview.isOpaque = false
    webview.backgroundColor = .clear
    webview.scrollView.backgroundColor = .clear

    self.videoView = view
    self.metalLayer = layer
    layoutMetal()
  }

  private func layoutMetal() {
    guard let view = videoView, let layer = metalLayer else { return }
    // NEVER touch the layer while the surface is occluded. The exit rotation
    // (landscape → portrait) is the only rotation that ever hits a LIVE mpv
    // swapchain (playback locks the orientation), and resizing drawableSize
    // here makes MoltenVK rebuild the swapchain from mpv's render thread
    // while the main thread is mid-rotation inside its own CATransaction on
    // the same layer — CALayer is not thread-safe, and that collision was the
    // exit freeze. While occluded the geometry doesn't matter; showVideo()
    // re-runs this once the surface is visible again.
    guard !surfaceHidden else { return }
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else { return }
    let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
    let drawable = CGSize(
      width: (bounds.width * scale).rounded(),
      height: (bounds.height * scale).rounded())
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contentsScale = scale
    layer.frame = bounds
    if drawable != lastAppliedDrawableSize {
      layer.drawableSize = drawable
      lastAppliedDrawableSize = drawable
    }
    CATransaction.commit()
  }

  private func ensureMpv() {
    guard mpv == nil else { return }
    ensureView()
    guard let layer = metalLayer else { return }

    let ctx = mpv_create()
    guard let ctx = ctx else { return }
    mpv = ctx

    var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    mpv_set_option(ctx, "wid", MPV_FORMAT_INT64, &wid)
    setOpt("vo", "gpu-next")
    setOpt("gpu-api", "vulkan")
    setOpt("gpu-context", "moltenvk")
    setOpt("hwdec", "videotoolbox")
    setOpt("ao", "audiounit")
    setOpt("audio-channels", "auto")
    setOpt("audio-fallback-to-null", "yes")
    setOpt("vulkan-swap-mode", "fifo")
    setOpt("video-rotate", "no")
    setOpt("keep-open", "yes")
    setOpt("subs-fallback", "yes")
    setOpt("subs-match-os-language", "yes")
    setOpt("cache", "yes")
    setOpt("demuxer-max-bytes", "64MiB")
    setOpt("network-timeout", "30")
    // The instance is reused for the app's lifetime. idle=yes keeps the core
    // alive if the playlist ever empties (a failed load, etc.) instead of
    // shutting down — a dead handle would break every later open.
    setOpt("idle", "yes")
    // Surface warnings/errors (vo/hwdec init failures, network errors) into
    // the probe log — low volume, invaluable when playback silently no-ops.
    mpv_request_log_messages(ctx, "warn")
    mpv_initialize(ctx)
  }

  // The poll timer only needs to run while a file is playing. Running it on the
  // home/detail screens would do a CATransaction/layoutMetal every 0.25s on the
  // main thread for nothing, competing with React's rendering.
  private func startPolling() {
    guard pollTimer == nil else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
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
        if surfaceHidden { showVideo() }
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
    layoutMetal()

    let pos = getDouble("time-pos")
    let dur = getDouble("duration")
    // Belt-and-braces reveal: if the FILE_LOADED event was somehow missed,
    // a loaded file (the old one is unloaded the moment `replace` starts, so
    // a duration can only come from the new file) still un-occludes the UI.
    if surfaceHidden, dur > 0 {
      debug("tick: reveal via duration")
      showVideo()
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

    let sig = "\(getInt("track-list/count"))-\(status)"
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
      let selected = getFlag("track-list/\(i)/selected")
      let label = !title.isEmpty ? title : (!lang.isEmpty ? lang : "\(type.capitalized) \(id)")
      var obj: JSObject = [:]
      obj["id"] = id
      obj["label"] = label
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
  private static let probeURL: URL = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("probe.log")
  }()
  static func probe(_ msg: String) {
    let t = Date().timeIntervalSince(probeEpoch)
    guard let data = String(format: "%.2f  %@\n", t, msg).data(using: .utf8) else { return }
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
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { invoke.resolve(); return }
      NativePlayerPlugin.probe("load begin")
      self.debug("load: begin")
      // De-dupe racing loads for the same URL. React can mount the player
      // twice (StrictMode / a fast remount), firing two `loadfile replace` in
      // the same instant; two concurrent VkSurface re-inits on one Metal layer
      // can wedge the GPU. The first load wins; the duplicate is a no-op.
      let now = Date().timeIntervalSince1970
      if args.url == self.lastLoadUrl, now - self.lastLoadAt < 1.5 {
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
      UIApplication.shared.isIdleTimerDisabled = true
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
    DispatchQueue.main.async { [weak self] in
      self?.setProp("pause", flag: false)
      invoke.resolve()
    }
  }

  @objc public func pause(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      self?.setProp("pause", flag: true)
      invoke.resolve()
    }
  }

  @objc public func stop(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      NativePlayerPlugin.probe("halt begin")
      self?.debug("stop: halt begin")
      self?.haltPlayback()
      self?.debug("stop: halt end")
      NativePlayerPlugin.probe("halt end")
      invoke.resolve()
      // Liveness ticker across the freeze window, independent of the webview:
      // if these lines keep appearing in the probe log, the native main
      // thread survived and the hang is inside the WebContent process.
      for d in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
          NativePlayerPlugin.probe(String(format: "main alive +%.1fs", d))
        }
      }
    }
  }

  @objc public func seek(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SeekArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.seekAbsolute(args.sec)
      invoke.resolve()
    }
  }

  @objc public func setVolume(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(VolumeArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.setProp("volume", double: max(0, min(1, args.volume)) * 100)
      invoke.resolve()
    }
  }

  @objc public func setMuted(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(MutedArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.setProp("mute", flag: args.muted)
      invoke.resolve()
    }
  }

  @objc public func setRate(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(RateArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.setProp("speed", double: args.rate)
      invoke.resolve()
    }
  }

  @objc public func setAudioTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.setProp("aid", int: Int64(args.id))
      invoke.resolve()
    }
  }

  @objc public func setSubtitleTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    DispatchQueue.main.async { [weak self] in
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
    DispatchQueue.main.async { [weak self] in
      self?.command(["sub-add", args.url, (args.select ?? true) ? "select" : "auto"])
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
    // the home screen's first render are past.
    DispatchQueue.main.async {
      NativePlayerPlugin.orientationMask = .portrait
      NativePlayerPlugin.probe("unlock: mask -> portrait")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      NativePlayerPlugin.probe("orient: apply begin")
      self?.debug("orient: portrait apply")
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        self?.webview?.window?.rootViewController?
          .setNeedsUpdateOfSupportedInterfaceOrientations()
      } else {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
      NativePlayerPlugin.probe("orient: apply end")
    }
  }

  private func applyLandscape() {
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
  private func haltPlayback() {
    UIApplication.shared.isIdleTimerDisabled = false
    lastLoadUrl = ""
    lastLoadAt = 0
    stopPolling()
    haltGen += 1
    let gen = haltGen
    // NEVER `stop` (unloading destroys the video output — swapchain teardown,
    // rule 1) and do NOTHING in this turn that touches video or CoreAnimation.
    // Exits from PAUSED already survive; exits from PLAYING still froze, and
    // the one remaining state change in this turn was `pause` itself — which
    // makes gpu-next repaint a frame right as WebKit commits the player
    // unmount. So the immediate halt is audio-only: MUTE (no repaint), and
    // the video keeps playing invisibly for a beat.
    setProp("mute", flag: true)
    surfaceHidden = true
    // Pause in a QUIET turn once the exit render storm has passed. The
    // generation guard makes this a no-op if the player was reopened.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
      guard let self = self, self.haltGen == gen else { return }
      NativePlayerPlugin.probe("halt: deferred pause")
      self.setProp("pause", flag: true)
    }
    // Occlude last, after the pause repaint has settled. The home screen's
    // DOM has a solid background (data-native-video was already removed), so
    // nothing shows through in the meantime.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
      guard let self = self, self.haltGen == gen, self.surfaceHidden else { return }
      NativePlayerPlugin.probe("halt: deferred occlude")
      self.hideVideo()
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

  // Full teardown of mpv. NOT used on the normal exit path (see haltPlayback);
  // kept for a real shutdown/memory-pressure hook. Runs the blocking
  // mpv_terminate_destroy off the main thread and keeps the layer alive until
  // it finishes so mpv's render thread can't touch a freed CAMetalLayer.
  private func teardown() {
    UIApplication.shared.isIdleTimerDisabled = false
    // mpv is about to be destroyed, so the next load must always go through —
    // clear the de-dupe key or a re-open of the same URL would be skipped.
    lastLoadUrl = ""
    lastLoadAt = 0
    pollTimer?.invalidate()
    pollTimer = nil
    let view = videoView
    videoView = nil
    metalLayer = nil
    if let webview = self.webview {
      webview.isOpaque = true
      webview.backgroundColor = .black
      webview.scrollView.backgroundColor = .black
    }
    // Detach the video view NOW so the webview UI is visible immediately, but
    // do NOT let it deallocate yet: mpv was handed a *raw* pointer to the
    // CAMetalLayer (via `wid`, passUnretained), and its render/vo thread keeps
    // touching that layer while it shuts down. Freeing the layer here would be
    // a use-after-free on mpv's background thread — a crash/hang that looked
    // exactly like the "freeze".
    view?.removeFromSuperview()
    // mpv_terminate_destroy blocks until the whole player has shut down — which
    // includes draining decode/network threads, so on a stalled stream it can
    // hang for seconds. Never run it on the main thread (that was the freeze).
    // Nil the handle so nothing else touches it, then destroy off-main.
    if let ctx = mpv {
      mpv = nil
      // Retain the view (and thus its MetalVideoLayer sublayer) until mpv is
      // fully torn down, so the `wid` pointer stays valid for the whole drain.
      let keepAlive = view
      DispatchQueue.global(qos: .userInitiated).async {
        mpv_terminate_destroy(ctx)
        // mpv is gone; the layer is now safe to release. Do it on the main
        // thread — UIView deallocation must happen there.
        DispatchQueue.main.async {
          _ = keepAlive
        }
      }
    }
  }

  // MARK: - mpv helpers

  private func command(_ args: [String]) {
    guard let mpv = mpv else { return }
    // strdup gives mutable copies we own and must free; mpv_command wants a
    // NULL-terminated `const char **`, so hand it UnsafePointer views.
    let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    defer { for p in owned where p != nil { free(p) } }
    var cargs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
    cargs.append(nil)
    cargs.withUnsafeMutableBufferPointer { buf in
      _ = mpv_command(mpv, buf.baseAddress)
    }
  }

  private func seekAbsolute(_ sec: Double) {
    command(["seek", String(format: "%.3f", sec), "absolute"])
  }

  private func setProp(_ name: String, flag: Bool) {
    guard let mpv = mpv else { return }
    var v: Int32 = flag ? 1 : 0
    mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
  }
  private func setProp(_ name: String, double: Double) {
    guard let mpv = mpv else { return }
    var v = double
    mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
  }
  private func setProp(_ name: String, int: Int64) {
    guard let mpv = mpv else { return }
    var v = int
    mpv_set_property(mpv, name, MPV_FORMAT_INT64, &v)
  }
  private func setPropString(_ name: String, _ value: String) {
    guard let mpv = mpv else { return }
    mpv_set_property_string(mpv, name, value)
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
