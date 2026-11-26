import Foundation
import AVFoundation
import MediaPlayer
import CoreMedia
import CoreGraphics

private struct WindowInfoDTO: Encodable {
    let windowNumber: Int
    let name: String?
    let layer: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    enum CodingKeys: String, CodingKey {
        case windowNumber = "window_number"
        case name
        case layer
        case x
        case y
        case width
        case height
    }
}

private struct CheckWindowResult: Encodable {
    let ok: Bool
    let pid: Int32
    let windowCount: Int
    let windows: [WindowInfoDTO]

    enum CodingKeys: String, CodingKey {
        case ok
        case pid
        case windowCount = "window_count"
        case windows
    }
}

private struct HLSProbeResult: Encodable {
    let ok: Bool
    let url: String
    let status: String
    let durationSec: Double
    let periodicTicks: Int
    let finalTimeSec: Double
    let ended: Bool
    let nowPlayingState: Int
    let nowPlayingTitle: String?
    let remoteCommandsRegistered: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case url
        case status
        case durationSec = "duration_sec"
        case periodicTicks = "periodic_ticks"
        case finalTimeSec = "final_time_sec"
        case ended
        case nowPlayingState = "now_playing_state"
        case nowPlayingTitle = "now_playing_title"
        case remoteCommandsRegistered = "remote_commands_registered"
        case error
    }
}

private func emitJSON<T: Encodable>(_ value: T, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("{\"ok\":false,\"error\":\"json_encode_failed\"}")
    }
    fflush(stdout)
    fflush(stderr)
    exit(exitCode)
}

private func checkWindow(pid: Int32) -> Never {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    var matched: [WindowInfoDTO] = []

    for info in rawList {
        guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32, ownerPid == pid else {
            continue
        }
        let winNum = info[kCGWindowNumber as String] as? Int ?? 0
        let name = info[kCGWindowName as String] as? String
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let boundsDict = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0.0
        let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0.0
        let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0.0
        let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0.0
        matched.append(WindowInfoDTO(windowNumber: winNum, name: name, layer: layer, x: x, y: y, width: w, height: h))
    }

    let result = CheckWindowResult(
        ok: !matched.isEmpty,
        pid: pid,
        windowCount: matched.count,
        windows: matched
    )
    emitJSON(result, exitCode: matched.isEmpty ? 1 : 0)
}

private final class HLSProbeRunner {
    private let url: URL
    private let timeoutSec: Double
    private var player: AVPlayer?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    private var statusString: String = "unknown"
    private var durationSec: Double = 0.0
    private var periodicTicks: Int = 0
    private var finalTimeSec: Double = 0.0
    private var ended: Bool = false
    private var failureMessage: String? = nil
    private var finished: Bool = false

    init(url: URL, timeoutSec: Double) {
        self.url = url
        self.timeoutSec = timeoutSec
    }

    func run() -> HLSProbeResult {
        // 1. Exercise MPNowPlayingInfoCenter & MPRemoteCommandCenter
        let infoCenter = MPNowPlayingInfoCenter.default()
        let probeTitle = "VKMac E2E Probe"
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: probeTitle,
            MPMediaItemPropertyArtist: "E2E Synth",
            MPMediaItemPropertyPlaybackDuration: 2.09,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        infoCenter.playbackState = .playing
        let observedPlaybackState = Int(infoCenter.playbackState.rawValue)
        let observedTitle = infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String

        let cmdCenter = MPRemoteCommandCenter.shared()
        let playTarget = cmdCenter.playCommand.addTarget { _ in .success }
        let pauseTarget = cmdCenter.pauseCommand.addTarget { _ in .success }
        let nextTarget = cmdCenter.nextTrackCommand.addTarget { _ in .success }
        let prevTarget = cmdCenter.previousTrackCommand.addTarget { _ in .success }

        // 2. Configure AVPlayer with live HLS URL
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.isMuted = true
        self.player = avPlayer

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak avPlayer] observedItem, _ in
            let status = observedItem.status
            let dur = CMTimeGetSeconds(observedItem.duration)
            let errDesc = observedItem.error?.localizedDescription
            DispatchQueue.main.async { [weak self, weak avPlayer] in
                guard let self = self, !self.finished else { return }
                switch status {
                case .unknown:
                    self.statusString = "unknown"
                case .readyToPlay:
                    self.statusString = "readyToPlay"
                    if dur.isFinite && dur > 0 {
                        self.durationSec = dur
                    }
                    avPlayer?.play()
                case .failed:
                    self.statusString = "failed"
                    self.failureMessage = errDesc ?? "AVPlayerItem failed"
                    self.finished = true
                @unknown default:
                    self.statusString = "other"
                }
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.periodicTicks += 1
            let sec = CMTimeGetSeconds(time)
            if sec.isFinite && sec >= 0 {
                self.finalTimeSec = sec
            }
            if let currentItem = avPlayer.currentItem {
                let dur = CMTimeGetSeconds(currentItem.duration)
                if dur.isFinite && dur > 0 {
                    self.durationSec = dur
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.ended = true
            let sec = CMTimeGetSeconds(avPlayer.currentTime())
            if sec.isFinite && sec >= 0 {
                self.finalTimeSec = max(self.finalTimeSec, sec)
            }
            self.finished = true
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            self.failureMessage = err?.localizedDescription ?? "Failed to play to end time"
            self.finished = true
        }

        let deadline = Date().addingTimeInterval(timeoutSec)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        if !finished && failureMessage == nil {
            failureMessage = "Timed out after \(timeoutSec)s (status=\(statusString), ended=\(ended))"
        }
        finished = true

        // Cleanup observers & remote targets
        if let token = timeObserverToken {
            avPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let eo = endObserver {
            NotificationCenter.default.removeObserver(eo)
            endObserver = nil
        }
        if let fo = failObserver {
            NotificationCenter.default.removeObserver(fo)
            failObserver = nil
        }
        avPlayer.pause()
        cmdCenter.playCommand.removeTarget(playTarget)
        cmdCenter.pauseCommand.removeTarget(pauseTarget)
        cmdCenter.nextTrackCommand.removeTarget(nextTarget)
        cmdCenter.previousTrackCommand.removeTarget(prevTarget)
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil

        let ok = (statusString == "readyToPlay") && durationSec > 0 && ended && (observedPlaybackState == 1)
        return HLSProbeResult(
            ok: ok,
            url: url.absoluteString,
            status: statusString,
            durationSec: durationSec,
            periodicTicks: periodicTicks,
            finalTimeSec: finalTimeSec,
            ended: ended,
            nowPlayingState: observedPlaybackState,
            nowPlayingTitle: observedTitle,
            remoteCommandsRegistered: true,
            error: ok ? nil : failureMessage
        )
    }
}

private func printHelp() {
    let msg = """
    Usage:
      hls_probe --url <m3u8_url> [--timeout <seconds>]
      hls_probe --check-window <pid>
      hls_probe --help
    """
    print(msg)
    fflush(stdout)
}

let args = CommandLine.arguments
if args.contains("--help") || args.contains("-h") {
    printHelp()
    exit(0)
}

var urlArg: String? = nil
var timeoutArg: Double = 10.0
var checkWindowPid: Int32? = nil

var idx = 1
while idx < args.count {
    let arg = args[idx]
    switch arg {
    case "--url":
        if idx + 1 < args.count {
            urlArg = args[idx + 1]
            idx += 2
        } else {
            fputs("Missing value for --url\n", stderr)
            exit(2)
        }
    case "--timeout":
        if idx + 1 < args.count, let val = Double(args[idx + 1]), val.isFinite, val > 0 {
            timeoutArg = val
            idx += 2
        } else {
            fputs("Invalid value for --timeout\n", stderr)
            exit(2)
        }
    case "--check-window":
        if idx + 1 < args.count, let pid = Int32(args[idx + 1]) {
            checkWindowPid = pid
            idx += 2
        } else {
            fputs("Invalid PID for --check-window\n", stderr)
            exit(2)
        }
    default:
        if arg.hasPrefix("http://") || arg.hasPrefix("https://") {
            urlArg = arg
            idx += 1
        } else {
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(2)
        }
    }
}

if let pid = checkWindowPid {
    checkWindow(pid: pid)
}

guard let rawUrl = urlArg else {
    fputs("Either --url <m3u8_url> or --check-window <pid> is required. Use --help for usage.\n", stderr)
    exit(2)
}

let trimmedUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmedUrl.isEmpty,
      let parsedUrl = URL(string: trimmedUrl),
      let scheme = parsedUrl.scheme,
      !scheme.isEmpty else {
    fputs("Invalid or empty URL for --url: '\(rawUrl)'\n", stderr)
    exit(2)
}

private let runner = HLSProbeRunner(url: parsedUrl, timeoutSec: timeoutArg)
private let res = runner.run()
emitJSON(res, exitCode: res.ok ? 0 : 1)
