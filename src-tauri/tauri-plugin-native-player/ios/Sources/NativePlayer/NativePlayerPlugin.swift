import AVFoundation
import CVLC
import Tauri
import UIKit
import WebKit

struct LoadArgs: Decodable {
  let url: String
  let startAtSec: Double?
}

struct SeekArgs: Decodable {
  let sec: Double
}

struct VolumeArgs: Decodable {
  let volume: Double
}

struct MutedArgs: Decodable {
  let muted: Bool
}

struct RateArgs: Decodable {
  let rate: Double
}

struct TrackArgs: Decodable {
  let id: Int
}

struct SubtitleArgs: Decodable {
  let url: String
  let select: Bool?
}

struct ProbeResponse: Encodable {
  let available: Bool
}

class NativePlayerPlugin: Plugin, VLCMediaPlayerDelegate {
  private var player: VLCMediaPlayer?
  private var videoView: UIView?
  private weak var webview: WKWebView?
  private var pendingStartAt: Double = 0
  private var appliedStartAt = true
  private var lastTracksSignature = ""

  @objc public override func load(webview: WKWebView) {
    self.webview = webview
  }

  // MARK: helpers

  private func ensureVideoView() {
    guard videoView == nil, let webview = self.webview, let superview = webview.superview else {
      return
    }
    let view = UIView(frame: superview.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .black
    superview.insertSubview(view, belowSubview: webview)
    webview.isOpaque = false
    webview.backgroundColor = .clear
    webview.scrollView.backgroundColor = .clear
    videoView = view
  }

  private func teardown() {
    UIApplication.shared.isIdleTimerDisabled = false
    // VLCMediaPlayer.stop() must never run on the main thread: it blocks on
    // the video output teardown, which itself needs the main thread — a
    // guaranteed deadlock (the app froze when leaving the player). Detach
    // everything on main, then stop on a background queue and only remove
    // the drawable view once VLC has fully released it.
    let stoppingPlayer = player
    let stoppingView = videoView
    player?.delegate = nil
    player = nil
    videoView = nil
    if let webview = self.webview {
      webview.isOpaque = true
      webview.backgroundColor = .black
      webview.scrollView.backgroundColor = .black
    }
    stoppingView?.isHidden = true
    // Rotate back to portrait as part of the same teardown pass so the exit
    // is one coherent sequence regardless of JS call ordering.
    if #available(iOS 16.0, *) {
      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
      scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
      webview?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
    }
    DispatchQueue.global(qos: .userInitiated).async {
      stoppingPlayer?.stop()
      DispatchQueue.main.async {
        stoppingView?.removeFromSuperview()
      }
    }
  }

  private func statusString(_ state: VLCMediaPlayerState) -> String {
    switch state {
    case .opening, .buffering:
      return "loading"
    case .playing:
      return "playing"
    case .paused:
      return "paused"
    case .ended, .stopped:
      return "ended"
    case .error:
      return "error"
    default:
      return "loading"
    }
  }

  private func trackList(indexes: [Any]?, names: [Any]?, current: Int32) -> [JSObject] {
    var out: [JSObject] = []
    guard let indexes = indexes, let names = names else { return out }
    for (i, rawId) in indexes.enumerated() {
      guard let id = (rawId as? NSNumber)?.intValue else { continue }
      if id == -1 { continue }
      let name = i < names.count ? (names[i] as? String ?? "Track \(id)") : "Track \(id)"
      var obj: JSObject = [:]
      obj["id"] = id
      obj["label"] = name
      obj["selected"] = id == Int(current)
      out.append(obj)
    }
    return out
  }

  private func emitStatus() {
    guard let player = self.player else { return }
    let audio = trackList(
      indexes: player.audioTrackIndexes, names: player.audioTrackNames,
      current: player.currentAudioTrackIndex)
    let subs = trackList(
      indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames,
      current: player.currentVideoSubTitleIndex)
    var data: JSObject = [:]
    data["status"] = statusString(player.state)
    data["buffering"] = player.state == .buffering || player.state == .opening
    data["durationSec"] = Double(player.media?.length.intValue ?? 0) / 1000.0
    data["rate"] = Double(player.rate)
    data["audioTracks"] = audio
    data["subtitleTracks"] = subs
    let size = player.videoSize
    data["videoWidth"] = Int(size.width)
    data["videoHeight"] = Int(size.height)
    trigger("status", data: data)
  }

  // MARK: delegate

  @objc public func mediaPlayerStateChanged(_ aNotification: Notification) {
    DispatchQueue.main.async { [weak self] in
      self?.emitStatus()
    }
  }

  @objc public func mediaPlayerTimeChanged(_ aNotification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let player = self.player else { return }
      if !self.appliedStartAt, self.pendingStartAt > 0, player.isSeekable {
        self.appliedStartAt = true
        player.time = VLCTime(int: Int32(self.pendingStartAt * 1000))
      }
      var data: JSObject = [:]
      data["positionSec"] = Double(player.time.intValue) / 1000.0
      data["durationSec"] = Double(player.media?.length.intValue ?? 0) / 1000.0
      self.trigger("time", data: data)
      let signature = "\(player.audioTrackIndexes?.count ?? 0)-\(player.videoSubTitlesIndexes?.count ?? 0)"
      if signature != self.lastTracksSignature {
        self.lastTracksSignature = signature
        self.emitStatus()
      }
    }
  }

  // MARK: commands

  @objc public func probe(_ invoke: Invoke) {
    invoke.resolve(ProbeResponse(available: true))
  }

  @objc public func load(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(LoadArgs.self)
    guard let url = URL(string: args.url) else {
      invoke.reject("invalid url")
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try? AVAudioSession.sharedInstance().setActive(true)
      self.teardownPlayerOnly()
      self.ensureVideoView()
      let player = VLCMediaPlayer()
      player.drawable = self.videoView
      player.delegate = self
      player.media = VLCMedia(url: url)
      self.pendingStartAt = args.startAtSec ?? 0
      self.appliedStartAt = self.pendingStartAt <= 0
      self.lastTracksSignature = ""
      self.player = player
      UIApplication.shared.isIdleTimerDisabled = true
      player.play()
      invoke.resolve()
    }
  }

  private func teardownPlayerOnly() {
    // Same main-thread deadlock hazard as teardown(): stop off-main.
    let stoppingPlayer = player
    player?.delegate = nil
    player = nil
    DispatchQueue.global(qos: .userInitiated).async {
      stoppingPlayer?.stop()
    }
  }

  @objc public func play(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      self?.player?.play()
      invoke.resolve()
    }
  }

  @objc public func pause(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      self?.player?.pause()
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
      guard let player = self?.player else {
        invoke.resolve()
        return
      }
      if player.isSeekable {
        player.time = VLCTime(int: Int32(args.sec * 1000))
      } else {
        let duration = Double(player.media?.length.intValue ?? 0) / 1000.0
        if duration > 0 {
          player.position = Float(args.sec / duration)
        }
      }
      invoke.resolve()
    }
  }

  @objc public func setVolume(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(VolumeArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.player?.audio?.volume = Int32(max(0, min(1, args.volume)) * 100)
      invoke.resolve()
    }
  }

  @objc public func setMuted(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(MutedArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.player?.audio?.isMuted = args.muted
      invoke.resolve()
    }
  }

  @objc public func setRate(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(RateArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.player?.rate = Float(args.rate)
      invoke.resolve()
    }
  }

  @objc public func setAudioTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.player?.currentAudioTrackIndex = Int32(args.id)
      invoke.resolve()
      self?.emitStatus()
    }
  }

  @objc public func setSubtitleTrack(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(TrackArgs.self)
    DispatchQueue.main.async { [weak self] in
      self?.player?.currentVideoSubTitleIndex = Int32(args.id)
      invoke.resolve()
      self?.emitStatus()
    }
  }

  @objc public func addSubtitle(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(SubtitleArgs.self)
    guard let url = URL(string: args.url) else {
      invoke.reject("invalid url")
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.player?.addPlaybackSlave(url, type: .subtitle, enforce: args.select ?? true)
      invoke.resolve()
    }
  }

  @objc public func lockLandscape(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        self?.webview?.window?.rootViewController?
          .setNeedsUpdateOfSupportedInterfaceOrientations()
      } else {
        UIDevice.current.setValue(
          UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
      }
      invoke.resolve()
    }
  }

  @objc public func unlockOrientation(_ invoke: Invoke) {
    DispatchQueue.main.async { [weak self] in
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        self?.webview?.window?.rootViewController?
          .setNeedsUpdateOfSupportedInterfaceOrientations()
      } else {
        UIDevice.current.setValue(
          UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
      invoke.resolve()
    }
  }
}

@_cdecl("init_plugin_native_player")
func initPlugin() -> Plugin {
  return NativePlayerPlugin()
}
