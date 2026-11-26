import AppKit
import SwiftUI

@MainActor
final class MiniPlayerWindow {
    static let shared = MiniPlayerWindow()
    private var window: NSWindow?

    func toggle(audioPlayer: AudioPlayerService, appState: AppState) {
        if let existing = window, existing.isVisible {
            existing.close()
            return
        }
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = FloatingMiniPlayerView()
            .environmentObject(audioPlayer)
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 124),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = hosting
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

private struct FloatingMiniPlayerView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if let track = audioPlayer.currentTrack {
                HStack(spacing: 10) {
                    if let cover = track.coverUrl, let url = URL(string: cover) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.secondary.opacity(0.2) }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                Slider(
                    value: Binding(
                        get: { audioPlayer.currentTime },
                        set: { audioPlayer.seek(to: $0) }
                    ),
                    in: 0...max(audioPlayer.duration, 1)
                )
                HStack(spacing: 20) {
                    Button { audioPlayer.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)
                    Button { audioPlayer.togglePlayPause() } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(appState.accentColor)
                    }
                    .buttonStyle(.borderless)
                    Button { audioPlayer.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Ничего не играет")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320, height: 124)
    }
}
