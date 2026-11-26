import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var showQueuePopover: Bool = false
    @State private var showLyricsPopover: Bool = false
    @State private var lyricsText: String = ""
    @State private var showEQPopover: Bool = false

    var body: some View {
        if let track = audioPlayer.currentTrack {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    coverView(urlString: track.coverUrl)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 160, maxWidth: 240, alignment: .leading)
                    .layoutPriority(1)

                    HStack(spacing: 8) {
                        Button {
                            audioPlayer.previousTrack()
                        } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            audioPlayer.togglePlayPause()
                        } label: {
                            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            audioPlayer.nextTrack()
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 6) {
                        Text(formatTime(audioPlayer.currentTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)

                        Slider(
                            value: Binding(
                                get: { audioPlayer.currentTime },
                                set: { audioPlayer.seek(to: $0) }
                            ),
                            in: 0...max(audioPlayer.duration, 1)
                        )
                        .frame(minWidth: 80)

                        Text(formatTime(audioPlayer.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                    }

                    HStack(spacing: 8) {
                        if let kbps = audioPlayer.bitrateKbps {
                            Text("\(kbps) kbps")
                                .font(.caption2.monospacedDigit())
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Button {
                            audioPlayer.isShuffle.toggle()
                        } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(audioPlayer.isShuffle ? appState.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Перемешать")

                        Button {
                            audioPlayer.cycleRepeatMode()
                        } label: {
                            Image(systemName: repeatIcon)
                                .foregroundStyle(audioPlayer.repeatMode == .off ? Color.secondary : appState.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .help("Повтор")

                        Button {
                            appState.infiniteWave.toggle()
                            appState.savePref(key: "infiniteWave", value: appState.infiniteWave ? "1" : "0")
                        } label: {
                            Image(systemName: "infinity")
                                .foregroundStyle(appState.infiniteWave ? appState.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Бесконечная волна")

                        HStack(spacing: 4) {
                            Image(systemName: audioPlayer.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $audioPlayer.volume, in: 0...1)
                                .frame(width: 64)
                        }

                        Menu {
                            ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                Button("\(String(format: "%.2gx", rate))") {
                                    audioPlayer.playbackRate = rate
                                }
                            }
                        } label: {
                            Text("\(String(format: "%.2gx", audioPlayer.playbackRate))")
                                .font(.caption2.monospacedDigit())
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 36)
                        .help("Скорость воспроизведения")

                        Menu {
                            Button("15 минут") { audioPlayer.setSleepTimer(minutes: 15) }
                            Button("30 минут") { audioPlayer.setSleepTimer(minutes: 30) }
                            Button("60 минут") { audioPlayer.setSleepTimer(minutes: 60) }
                            Divider()
                            Button("Отключить таймер") { audioPlayer.setSleepTimer(minutes: nil) }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "moon.zzz")
                                if let mins = audioPlayer.sleepTimerMinutesRemaining {
                                    Text("\(mins)м")
                                        .font(.caption2)
                                }
                            }
                            .foregroundStyle(audioPlayer.sleepTimerMinutesRemaining != nil ? appState.accentColor : Color.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: audioPlayer.sleepTimerMinutesRemaining != nil ? 44 : 24)
                        .help("Таймер сна")

                        Button {
                            Task { await appState.setBroadcast(ownerId: track.ownerId, audioId: track.id) }
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Транслировать в статус ВК")

                        Button {
                            showQueuePopover.toggle()
                        } label: {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Очередь воспроизведения")
                        .popover(isPresented: $showQueuePopover) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Далее в очереди (\(audioPlayer.queue.count))")
                                    .font(.headline)
                                List(Array(audioPlayer.queue.enumerated()), id: \.offset) { idx, qTrack in
                                    HStack {
                                        Button {
                                            audioPlayer.playAt(index: idx)
                                        } label: {
                                            HStack {
                                                if idx == audioPlayer.currentIndex {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .foregroundStyle(appState.accentColor)
                                                }
                                                Text("\(qTrack.artist) — \(qTrack.title)")
                                                    .font(.caption)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        Spacer()
                                        if idx != audioPlayer.currentIndex {
                                            Button {
                                                audioPlayer.removeFromQueue(at: idx)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                                .frame(width: 300, height: 240)
                            }
                            .padding(10)
                        }

                        Group {
                            Button {
                                lyricsText = "Загрузка..."
                                showLyricsPopover.toggle()
                                Task { lyricsText = await appState.getAudioLyrics(ownerId: track.ownerId, audioId: track.id) }
                            } label: {
                                Image(systemName: "text.quote")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Текст песни")
                            .popover(isPresented: $showLyricsPopover) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(track.artist) — \(track.title)")
                                        .font(.headline)
                                    ScrollView {
                                        Text(lyricsText.isEmpty ? "Текст не найден" : lyricsText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(12)
                                .frame(width: 320, height: 300)
                            }

                            Button {
                                showEQPopover.toggle()
                            } label: {
                                Image(systemName: "slider.vertical.3")
                                    .foregroundStyle(appState.eqPreset == "Обычный" ? Color.secondary : appState.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .help("Эквалайзер")
                            .popover(isPresented: $showEQPopover) {
                                EQPopoverView()
                                    .environmentObject(appState)
                            }

                            Button {
                                MiniPlayerWindow.shared.toggle(audioPlayer: audioPlayer, appState: appState)
                            } label: {
                                Image(systemName: "pip")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Мини-окно плеера")

                            Button {
                                audioPlayer.stop()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Закрыть плеер")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(height: 58)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var repeatIcon: String {
        switch audioPlayer.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    @ViewBuilder
    private func coverView(urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholderCover
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.18))
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
        .frame(width: 38, height: 38)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct EQPopoverView: View {
    @EnvironmentObject private var appState: AppState
    private let freqs = ["60Hz", "230Hz", "910Hz", "3.6k", "14k"]
    private let presets: [String: [Float]] = [
        "Обычный": [0, 0, 0, 0, 0],
        "Рок": [4, 2, -1, 3, 5],
        "Бас": [6, 4, 0, -1, 0],
        "Вокал": [-2, 0, 4, 5, 2],
        "Электроника": [5, 3, 0, 3, 4]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Эквалайзер")
                .font(.headline)
            Picker("Пресет", selection: $appState.eqPreset) {
                ForEach(["Обычный", "Рок", "Бас", "Вокал", "Электроника"], id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .onChange(of: appState.eqPreset) { val in
                if let bands = presets[val] {
                    appState.eqBands = bands
                }
            }
            ForEach(0..<5, id: \.self) { idx in
                HStack {
                    Text(freqs[idx])
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { appState.eqBands[idx] },
                            set: { appState.eqBands[idx] = $0 }
                        ),
                        in: -12...12
                    )
                    Text("\(Int(appState.eqBands[idx]))dB")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
