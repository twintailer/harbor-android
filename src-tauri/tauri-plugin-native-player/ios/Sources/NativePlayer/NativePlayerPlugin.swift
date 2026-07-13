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
  private var lastTimeEmit: TimeInterval = 0

  @objc public override func load(webview: WKWebView) {
    self.webview = webview
    // Returning from the background drops the requested geometry; re-assert
    // landscape while a video is active so the player does not come back in
    // portrait.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.player != nil else { return }
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        self.webview?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      }
    }
  }

  // MARK: helpers

  private func teardown() {
    UIApplication.shared.isIdleTimerDisabled = false
    // CRITICAL: never call removeFromSuperview() on a still-playing player's
    // drawable. Tearing the view out from under a live VLC video output
    // synchronises with the vout on the main thread and hangs the app — this
    // was the back-button freeze. Instead make the webview opaque and hide the
    // video view immediately (so the web UI is visible and responsive at once),
    // stop the player off the main thread, and only remove the now-dead view
    // afterwards. stop() runs on a plain concurrent global queue: never main
    // (on-main stop deadlocks on the vout teardown) and never a shared serial
    // queue (a stalled network stop() would block later teardowns).
    let stoppingPlayer = player
    let stoppingView = videoView
    stoppingPlayer?.delegate = nil
    player = nil
    videoView = nil
    if let webview = self.webview {
      webview.isOpaque = true
      webview.backgroundColor = .black
      webview.scrollView.backgroundColor = .black
    }
    stoppingView?.isHidden = true
    // Orientation is reset separately by the JS unmount (unlock_orientation);
    // doing it here in the same pass as the React teardown raced the relayout.
    guard let stoppingPlayer = stoppingPlayer else {
      stoppingView?.removeFromSuperview()
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      stoppingPlayer.stop()
      DispatchQueue.main.async { stoppingView?.removeFromSuperview() }
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
      // VLCKit fires this ~4x/second; each emit is a full IPC hop to JS that
      // re-renders the whole player chrome. Once per ~600ms is plenty for a
      // seek bar and roughly halves the idle CPU/heat during playback.
      let now = Date().timeIntervalSince1970
      if now - self.lastTimeEmit < 0.6 { return }
      self.lastTimeEmit = now
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
      guard let self = self, let webview = self.webview, let superview = webview.superview
      else {
        invoke.resolve()
        return
      }
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try? AVAudioSession.sharedInstance().setActive(true)

      // Retire the previous player BEFORE the new one starts. Two live
      // VLCMediaPlayers overlapping (the old one still decoding while a new one
      // spins up) contend on the shared libvlc instance and hang the app on the
      // next-episode switch. stop() must run off the main thread (it blocks on
      // the video-output teardown which needs main -> deadlock), so we stop the
      // old player on a background thread and only then start the new one. A
      // timeout guards against a network stream whose stop() stalls.
      let oldPlayer = self.player
      let oldView = self.videoView
      oldPlayer?.delegate = nil
      oldView?.isHidden = true

      // Build the new player + its own drawable view now (needs the main
      // thread), but do not call play() until the old one is torn down.
      let newView = UIView(frame: superview.bounds)
      newView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      newView.backgroundColor = .black
      superview.insertSubview(newView, belowSubview: webview)
      webview.isOpaque = false
      webview.backgroundColor = .clear
      webview.scrollView.backgroundColor = .clear

      let newPlayer = VLCMediaPlayer()
      newPlayer.drawable = newView
      newPlayer.delegate = self
      newPlayer.media = VLCMedia(url: url)

      self.player = newPlayer
      self.videoView = newView
      self.pendingStartAt = args.startAtSec ?? 0
      self.appliedStartAt = self.pendingStartAt <= 0
      self.lastTracksSignature = ""
      UIApplication.shared.isIdleTimerDisabled = true
      invoke.resolve()

      // Start the new player (guarded so the stop-completion and the timeout
      // can't double-fire it). The old VIEW is never removed here: pulling a
      // still-playing player's drawable out of the hierarchy hangs the app, so
      // it is only removed inside the stop completion, after the old player is
      // actually dead. Until then the old view sits hidden behind the new one.
      var started = false
      let startNew: () -> Void = {
        if started { return }
        started = true
        if self.player === newPlayer { newPlayer.play() }
      }

      if let oldPlayer = oldPlayer {
        oldView?.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async {
          oldPlayer.stop()
          DispatchQueue.main.async {
            startNew()
            oldView?.removeFromSuperview()
          }
        }
        // Don't wait forever if the old stream's stop() stalls on the network.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: startNew)
      } else {
        newPlayer.play()
      }
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
    // Resolve first, then rotate on a later runloop turn. Rotating in the same
    // pass that React is tearing the player UI down raced the webview relayout
    // and hung the app on the back button.
    invoke.resolve()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      if #available(iOS 16.0, *) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        self?.webview?.window?.rootViewController?
          .setNeedsUpdateOfSupportedInterfaceOrientations()
      } else {
        UIDevice.current.setValue(
          UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
    }
  }
}

@_cdecl("init_plugin_native_player")
func initPlugin() -> Plugin {
  return NativePlayerPlugin()
}
