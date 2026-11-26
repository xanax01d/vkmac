import SwiftUI
import WebKit

struct VideosView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchQuery: String = ""
    @State private var selectedVideo: VideoItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Поиск видео...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await appState.searchVideos(query: searchQuery) }
                    }

                Button("Найти") {
                    Task { await appState.searchVideos(query: searchQuery) }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(Array(appState.videos.enumerated()), id: \.offset) { index, video in
                        Button {
                            let media = appState.videos.map {
                                MediaViewerItem.video(
                                    id: $0.id,
                                    ownerId: $0.ownerId,
                                    accessKey: $0.accessKey,
                                    title: $0.title,
                                    streamUrl: $0.streamUrl,
                                    playerUrl: $0.playerUrl,
                                    thumbnailUrl: $0.thumbnailUrl,
                                    qualities: $0.qualities
                                )
                            }
                            PhotoViewerWindow.shared.showMedia(media, initialIndex: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    if let thumb = video.thumbnailUrl, let url = URL(string: thumb) {
                                        AsyncImage(url: url) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Rectangle().fill(Color.secondary.opacity(0.15))
                                        }
                                        .frame(height: 150)
                                        .clipped()
                                    } else {
                                        ZStack {
                                            Rectangle().fill(Color.secondary.opacity(0.15))
                                            Image(systemName: "play.rectangle.fill")
                                                .font(.largeTitle)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(height: 150)
                                    }

                                    Text(formatDuration(video.durationSec))
                                        .font(.caption2.monospacedDigit().bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.75))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .padding(6)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text(video.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)

                                Text("\(video.views) просмотров")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
        .navigationTitle("Видео")
        .toolbar {
            ToolbarItem {
                Button {
                    searchQuery = ""
                    Task { await appState.loadVideos() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить видео")
            }
        }
        .task {
            if appState.videos.isEmpty {
                await appState.loadVideos()
            }
        }
        .sheet(item: Binding<IdentifiableVideo?>(
            get: { selectedVideo.map(IdentifiableVideo.init(video:)) },
            set: { selectedVideo = $0?.video }
        )) { item in
            VStack(spacing: 0) {
                HStack {
                    Text(item.video.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let playerStr = item.video.playerUrl, let url = URL(string: playerStr) {
                        Button("Открыть в браузере") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Закрыть") {
                        selectedVideo = nil
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                if let playerStr = item.video.playerUrl, let url = URL(string: playerStr) {
                    VideoPlayerWebView(url: url)
                } else {
                    Text("Плеер недоступен для этого видео")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 820, height: 540)
        }
    }

    private func formatDuration(_ sec: UInt32) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private struct IdentifiableVideo: Identifiable {
    let video: VideoItem
    var id: String { "\(video.ownerId)_\(video.id)" }
}

private struct VideoPlayerWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
