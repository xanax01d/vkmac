import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MusicSegment: String, CaseIterable {
    case tracks = "Мои треки"
    case playlists = "Плейлисты"
    case recommendations = "Рекомендации"
    case offline = "Скачанное"
    case history = "История"
    case stats = "Итоги"
}

private enum TrackSortOrder: String, CaseIterable {
    case original = "По умолчанию"
    case title = "По названию"
    case artist = "По исполнителю"
    case duration = "По длительности"
}

struct MusicView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var searchQuery: String = ""
    @State private var segment: MusicSegment = .tracks
    @State private var sortOrder: TrackSortOrder = .original
    @State private var sendToChatTrack: AudioTrack?
    @State private var lyricsTitle: String = ""
    @State private var lyricsText: String = ""
    @State private var showLyricsSheet: Bool = false
    @State private var showNewPlaylistAlert: Bool = false
    @State private var newPlaylistTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $segment) {
                    ForEach(MusicSegment.allCases, id: \.self) { seg in
                        Text(seg.rawValue).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    TextField("Поиск или фильтр...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            segment = .tracks
                            Task { await appState.searchAudio(query: searchQuery) }
                        }

                    Button("Найти") {
                        segment = .tracks
                        Task { await appState.searchAudio(query: searchQuery) }
                    }
                    .buttonStyle(.bordered)

                    Picker("", selection: $sortOrder) {
                        ForEach(TrackSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            .padding(12)

            Divider()

            if segment == .playlists {
                List(appState.playlists, id: \.id) { pl in
                    Button {
                        segment = .tracks
                        Task { await appState.loadPlaylistTracks(pl) }
                    } label: {
                        HStack(spacing: 12) {
                            if let cover = pl.coverUrl, let url = URL(string: cover) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.2)
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.18))
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 44, height: 44)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.title)
                                    .font(.body.weight(.medium))
                                Text("\(pl.count) треков")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            } else if segment == .recommendations {
                trackList(sortedAndFiltered(appState.recommendedTracks), isMine: false)
            } else if segment == .offline {
                trackList(sortedAndFiltered(appState.offlineTracks), isMine: false, isOfflineTab: true)
            } else if segment == .history {
                trackList(sortedAndFiltered(appState.listeningHistory), isMine: false)
            } else if segment == .stats {
                List {
                    Section("Топ исполнителей (по вашей истории)") {
                        if appState.topArtists.isEmpty {
                            Text("Послушайте несколько треков, чтобы собрать статистику")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appState.topArtists, id: \.artist) { stat in
                                HStack {
                                    Text(stat.artist)
                                    Spacer()
                                    Text("\(stat.playCount) прослуш.")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    Section("Офлайн-кэш") {
                        Text("Сохранено треков локально: \(appState.offlineAudioIds.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            } else {
                trackList(sortedAndFiltered(appState.tracks), isMine: true)
            }
        }
        .navigationTitle("Музыка")
        .toolbar {
            ToolbarItemGroup {
                if segment == .playlists {
                    Button {
                        showNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Создать плейлист")
                }
                Button {
                    exportTracksList()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Экспорт треков (.m3u / .txt)")
                Button {
                    searchQuery = ""
                    Task {
                        switch segment {
                        case .playlists: await appState.loadPlaylists()
                        case .recommendations: await appState.loadRecommendations()
                        case .offline: appState.refreshOfflineAudioList()
                        case .history: appState.loadListeningHistory()
                        case .stats: appState.loadTopArtists()
                        case .tracks: await appState.loadAudio()
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить музыку")
            }
        }
        .onChange(of: segment) { newSeg in
            if newSeg == .playlists && appState.playlists.isEmpty {
                Task { await appState.loadPlaylists() }
            } else if newSeg == .recommendations && appState.recommendedTracks.isEmpty {
                Task { await appState.loadRecommendations() }
            } else if newSeg == .offline {
                appState.refreshOfflineAudioList()
            } else if newSeg == .history {
                appState.loadListeningHistory()
            } else if newSeg == .stats {
                appState.loadTopArtists()
            }
        }
        .sheet(isPresented: $showLyricsSheet) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(lyricsTitle).font(.headline)
                    Spacer()
                    Button("Закрыть") { showLyricsSheet = false }
                }
                ScrollView {
                    Text(lyricsText.isEmpty ? "Текст песни не найден" : lyricsText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(width: 420, height: 460)
        }
        .alert("Новый плейлист", isPresented: $showNewPlaylistAlert) {
            TextField("Название", text: $newPlaylistTitle)
            Button("Создать") {
                let t = newPlaylistTitle
                newPlaylistTitle = ""
                Task { await appState.createPlaylist(title: t) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: Binding<IdentifiableTrack?>(
            get: { sendToChatTrack.map(IdentifiableTrack.init(track:)) },
            set: { if $0 == nil { sendToChatTrack = nil } }
        )) { wrapped in
            SendTrackToChatSheet(track: wrapped.track) { peerId in
                Task {
                    await appState.sendAudioAttachment(
                        peerId: peerId,
                        ownerId: wrapped.track.ownerId,
                        audioId: wrapped.track.id
                    )
                }
                sendToChatTrack = nil
            }
            .environmentObject(appState)
        }
        .task {
            if appState.tracks.isEmpty {
                await appState.loadAudio()
            }
        }
    }

    @ViewBuilder
    private func trackList(_ items: [AudioTrack], isMine: Bool, isOfflineTab: Bool = false) -> some View {
        List(items, id: \.id) { track in
            let isCurrent = audioPlayer.currentTrack?.id == track.id && audioPlayer.currentTrack?.ownerId == track.ownerId
            HStack(spacing: 12) {
                Button {
                    if isCurrent {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(track: track, in: items)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isCurrent && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isCurrent ? appState.accentColor : Color.primary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.body.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? appState.accentColor : Color.primary)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if appState.offlineAudioIds.contains(appState.offlineAudioKey(track)) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Сохранён офлайн")
                }

                Text(formatDuration(track.durationSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Играть следующим") {
                    audioPlayer.playNext(track)
                }
                Button("Похожие треки (Волна)") {
                    Task { await appState.playSimilarTracks(track) }
                }
                Button("Текст песни") {
                    lyricsTitle = "\(track.artist) — \(track.title)"
                    lyricsText = "Загрузка..."
                    showLyricsSheet = true
                    Task {
                        lyricsText = await appState.getAudioLyrics(ownerId: track.ownerId, audioId: track.id)
                    }
                }
                if isOfflineTab || appState.offlineAudioIds.contains(appState.offlineAudioKey(track)) {
                    Button("Удалить из офлайн-кэша", role: .destructive) {
                        appState.removeOfflineAudio(track)
                    }
                } else {
                    Button("Скачать офлайн") {
                        Task { await appState.downloadAudioOffline(track) }
                    }
                }
                if isMine {
                    Button("Удалить из моих аудиозаписей", role: .destructive) {
                        Task { await appState.deleteAudio(ownerId: track.ownerId, audioId: track.id) }
                    }
                } else {
                    Button("Добавить в мои аудиозаписи") {
                        Task { await appState.addAudio(ownerId: track.ownerId, audioId: track.id) }
                    }
                }
                if !appState.playlists.isEmpty {
                    Menu("Добавить в плейлист") {
                        ForEach(appState.playlists, id: \.id) { pl in
                            Button(pl.title) {
                                Task { await appState.addToPlaylist(ownerId: pl.ownerId, playlistId: pl.id, track: track) }
                            }
                        }
                    }
                }
                Button("Транслировать в статус") {
                    Task { await appState.setBroadcast(ownerId: track.ownerId, audioId: track.id) }
                }
                Button("Отправить в чат...") {
                    sendToChatTrack = track
                }
            }
        }
        .listStyle(.inset)
    }

    private func formatDuration(_ sec: UInt32) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private func sortedAndFiltered(_ list: [AudioTrack]) -> [AudioTrack] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? list : list.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
        switch sortOrder {
        case .original: return filtered
        case .title: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return filtered.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .duration: return filtered.sorted { $0.durationSec < $1.durationSec }
        }
    }

    private func exportTracksList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "vk_tracks.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = segment == .offline ? appState.offlineTracks : appState.tracks
        var lines = ["#EXTM3U"]
        for t in source {
            lines.append("#EXTINF:\(t.durationSec),\(t.artist) - \(t.title)")
            lines.append(t.streamUrl ?? "")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct IdentifiableTrack: Identifiable {
    let track: AudioTrack
    var id: Int64 { track.id }
}

private struct SendTrackToChatSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let track: AudioTrack
    let onSelectPeer: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отправить «\(track.title)» в чат")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            List(appState.conversations, id: \.peerId) { conv in
                Button {
                    onSelectPeer(conv.peerId)
                } label: {
                    HStack {
                        AvatarView(urlString: conv.avatarUrl, title: conv.title, size: 28)
                        Text(conv.title)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360, height: 400)
    }
}
