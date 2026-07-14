import AVFoundation
import Cmpv
import Tauri
import UIKit
import WebKit

// Native video playback backed by libmpv (the same engine Harbor uses on the
// desktop). mpv renders into a CAMetalLayer that sits behind the transparent
// webview, and switches media with `loadfile … replace` — so changing episodes
// never tears anything down, and exit is a clean mpv_terminate_destroy. This
// replaced a VLCKit backend whose video-output teardown deadlocked the main
// thread on exit / episode change.

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

  @objc public override func load(webview: WKWebView) {
    self.webview = webview
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.mpv != nil else { return }
      self.applyLandscape()
    }
    NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.layoutMetal()
    }
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
    mpv_initialize(ctx)

    // Drain and emit state on a timer (simpler and robust vs. the event loop).
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.tick()
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
    UIApplication.shared.isIdleTimerDisabled = true
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
    }
    layoutMetal()

    let pos = getDouble("time-pos")
    let dur = getDouble("duration")
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

  @objc public func probe(_ invoke: Invoke) {
    invoke.resolve(ProbeResponse(available: true))
  }

  @objc public func load(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(LoadArgs.self)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { invoke.resolve(); return }
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try? AVAudioSession.sharedInstance().setActive(true)
      self.ensureMpv()
      self.pendingStartAt = args.startAtSec ?? 0
      self.startApplied = self.pendingStartAt <= 0
      self.lastTracksSignature = ""
      self.ended = false
      // `replace` swaps media in-place — no teardown, so next/prev episode is
      // just another loadfile with nothing to free.
      self.command(["loadfile", args.url, "replace"])
      self.setProp("pause", flag: false)
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
      self?.teardown()
      invoke.resolve()
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
      self?.applyLandscape()
      invoke.resolve()
    }
  }

  @objc public func unlockOrientation(_ invoke: Invoke) {
    invoke.resolve()
    // Rotate back to portrait a beat later, off the teardown critical path.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        self?.webview?.window?.rootViewController?
          .setNeedsUpdateOfSupportedInterfaceOrientations()
      } else {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
    }
  }

  private func applyLandscape() {
    if #available(iOS 16.0, *) {
      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
      scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
      webview?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
    }
  }

  // MARK: - teardown

  private func teardown() {
    UIApplication.shared.isIdleTimerDisabled = false
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
    view?.removeFromSuperview()
    // mpv_terminate_destroy is safe on the main thread and does not block on a
    // video-output sync (unlike VLCKit's stop) — this is the whole reason for
    // moving to mpv. Nil the handle first so nothing else touches it.
    if let ctx = mpv {
      mpv = nil
      mpv_terminate_destroy(ctx)
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
