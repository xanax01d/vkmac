import AppKit
import AVKit
import SwiftUI
import WebKit

enum MediaViewerItem: Equatable {
    case photo(url: String)
    case video(
        id: Int64,
        ownerId: Int64,
        accessKey: String?,
        title: String,
        streamUrl: String?,
        playerUrl: String?,
        thumbnailUrl: String?,
        qualities: [VideoQualityOption]
    )

    var thumbnailString: String? {
        switch self {
        case .photo(let url): return url
        case .video(_, _, _, _, _, _, let thumb, _): return thumb
        }
    }

    var externalURL: URL? {
        switch self {
        case .photo(let url): return URL(string: url)
        case .video(_, _, _, _, let streamUrl, let playerUrl, _, _):
            return playerUrl.flatMap(URL.init(string:)) ?? streamUrl.flatMap(URL.init(string:))
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

struct MediaPresentation: Identifiable {
    let id = UUID()
    let items: [MediaViewerItem]
    let initialIndex: Int
}

@MainActor
final class PhotoViewerWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PhotoViewerWindow()
    @Published var activePresentation: MediaPresentation?
    private var window: NSWindow?
    var videoResolver: ((Int64, Int64, String?) async -> VideoItem?)?
    var mediaCommentsLoader: ((Bool, Int64, Int64) async -> [CommentItem])?
    var mediaCommentCreator: ((Bool, Int64, Int64, String) async -> Void)?

    func show(urls: [String], initialIndex: Int = 0) {
        let items = urls
            .filter { URL(string: $0) != nil }
            .map { MediaViewerItem.photo(url: $0) }
        showMedia(items, initialIndex: initialIndex)
    }

    func showMedia(_ items: [MediaViewerItem], initialIndex: Int = 0) {
        guard !items.isEmpty else { return }
        let clampedIndex = max(0, min(initialIndex, items.count - 1))
        activePresentation = MediaPresentation(items: items, initialIndex: clampedIndex)
    }

    func close() {
        activePresentation = nil
        window?.close()
    }

    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        // Immediately tear down the SwiftUI hierarchy, AVPlayer, and WKWebView
        // so video playback stops and disappears from macOS Control Center.
        window?.contentViewController = nil
    }
}

struct PhotoViewerView: View {
    let items: [MediaViewerItem]
    let onClose: () -> Void

    @State private var currentIndex: Int
    @State private var scale: CGFloat = 1.0
    @State private var saveStatus: String?
    @State private var videoPlayer: AVPlayer?
    @State private var videoStatusObservation: NSKeyValueObservation?
    @State private var videoFallbackToWeb: Bool = false
    @State private var isResolvingVideo: Bool = false
    @State private var resolvedStreams: [Int: (streamUrl: String?, playerUrl: String?, qualities: [VideoQualityOption])] = [:]
    @State private var selectedQualityByIndex: [Int: VideoQualityOption] = [:]
    @State private var isAlwaysOnTop: Bool = false
    @State private var showCommentsDrawer: Bool = false
    @State private var mediaComments: [CommentItem] = []
    @State private var newCommentText: String = ""

    init(items: [MediaViewerItem], initialIndex: Int, onClose: @escaping () -> Void) {
        self.items = items
        self._currentIndex = State(initialValue: initialIndex)
        self.onClose = onClose
    }

    private var currentItem: MediaViewerItem {
        items[max(0, min(currentIndex, items.count - 1))]
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.06)
                .ignoresSafeArea()

            mediaStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if items.count > 1 {
                HStack {
                    Button {
                        goPrevious()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(currentIndex == 0)
                    .opacity(currentIndex == 0 ? 0.2 : 0.9)
                    .padding(.leading, 18)

                    Spacer()

                    Button {
                        goNext()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(currentIndex >= items.count - 1)
                    .opacity(currentIndex >= items.count - 1 ? 0.2 : 0.9)
                    .padding(.trailing, 18)
                }
            }

            VStack {
                topOverlay
                Spacer()
                bottomOverlay
            }

            if showCommentsDrawer {
                HStack {
                    Spacer()
                    mediaCommentsPanel
                }
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .onAppear {
            syncVideoPlayer()
        }
        .onChange(of: currentIndex) { _ in
            syncVideoPlayer()
        }
        .onDisappear {
            stopVideoPlayer()
        }
        .touchBar {
            if items.count > 1 {
                Button { goPrevious() } label: { Image(systemName: "chevron.left") }
                Button { goNext() } label: { Image(systemName: "chevron.right") }
            }
            if !currentItem.isVideo {
                Button { scale = max(1.0, scale - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = min(4.0, scale + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            Button {
                isAlwaysOnTop.toggle()
                PhotoViewerWindow.shared.setFloating(isAlwaysOnTop)
            } label: {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
            }
            Button {
                stopVideoPlayer()
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
        }
    }

    @ViewBuilder
    private var mediaStage: some View {
        switch currentItem {
        case .photo(let urlStr):
            if let url = URL(string: urlStr) {
                ScrollView([.horizontal, .vertical], showsIndicators: scale > 1.01) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .controlSize(.large)
                                .frame(width: 500, height: 400)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .frame(
                                    maxWidth: scale > 1.01 ? .infinity : 940,
                                    maxHeight: scale > 1.01 ? .infinity : 610
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        scale = scale > 1.01 ? 1.0 : 2.0
                                    }
                                }
                        case .failure:
                            VStack(spacing: 10) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("Не удалось загрузить изображение")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 400, height: 300)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(minWidth: 780, minHeight: 520)
                    .padding(.vertical, 48)
                }
            }

        case .video(_, _, _, let title, let streamUrl, let playerUrl, _, _):
            let effectiveStream = selectedQualityByIndex[currentIndex]?.url ?? resolvedStreams[currentIndex]?.streamUrl ?? streamUrl
            let effectivePlayer = resolvedStreams[currentIndex]?.playerUrl ?? playerUrl
            if isResolvingVideo {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Загрузка видео «\(title)»...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !videoFallbackToWeb, effectiveStream != nil, let player = videoPlayer {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 68)
                    .padding(.top, 52)
                    .padding(.bottom, items.count > 1 ? 118 : 72)
            } else if let effectivePlayer, let url = URL(string: effectivePlayer) {
                TGVideoWebView(url: url)
                    .id(effectivePlayer)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 68)
                    .padding(.top, 52)
                    .padding(.bottom, items.count > 1 ? 118 : 72)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Плеер недоступен для «\(title)»")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private var topOverlay: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if case .video(_, _, _, let title, _, _, _, _) = currentItem {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if items.count > 1 {
                    Text("\(currentIndex + 1) из \(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5))
            .clipShape(Capsule())

            Spacer()

            if case .video(let vid, let oid, _, let title, let streamUrl, _, _, let qualities) = currentItem {
                Button {
                    showCommentsDrawer.toggle()
                    if showCommentsDrawer {
                        Task {
                            mediaComments = await PhotoViewerWindow.shared.mediaCommentsLoader?(true, oid, vid) ?? []
                        }
                    }
                } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(showCommentsDrawer ? Color.accentColor : .white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Комментарии")

                let effectiveUrl = selectedQualityByIndex[currentIndex]?.url
                    ?? resolvedStreams[currentIndex]?.streamUrl
                    ?? qualities.first?.url
                    ?? streamUrl
                if let effectiveUrl, let url = URL(string: effectiveUrl) {
                    Button {
                        downloadVideo(url: url, title: title)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Скачать MP4")
                }
            }

            Button {
                isAlwaysOnTop.toggle()
                PhotoViewerWindow.shared.setFloating(isAlwaysOnTop)
            } label: {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isAlwaysOnTop ? Color.accentColor : .white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Поверх всех окон (PiP)")

            Button {
                stopVideoPlayer()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    @MainActor
    private var bottomOverlay: some View {
        VStack(spacing: 10) {
            if items.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            Button {
                                selectIndex(idx)
                            } label: {
                                ZStack {
                                    if let thumb = item.thumbnailString, let url = URL(string: thumb) {
                                        AsyncImage(url: url) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.white.opacity(0.1)
                                        }
                                    } else {
                                        Color.white.opacity(0.12)
                                    }

                                    if item.isVideo {
                                        Image(systemName: "play.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(Color.black.opacity(0.6))
                                            .clipShape(Circle())
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(idx == currentIndex ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .opacity(idx == currentIndex ? 1.0 : 0.6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: 640)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 12) {
                if !currentItem.isVideo {
                    Button {
                        withAnimation { scale = max(0.5, scale - 0.25) }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)

                    Button("\(Int(scale * 100))%") {
                        withAnimation { scale = 1.0 }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())

                    Button {
                        withAnimation { scale = min(4.0, scale + 0.25) }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 14)

                    Button {
                        saveCurrentPhoto()
                    } label: {
                        Label(saveStatus ?? "Сохранить", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                if currentItem.isVideo {
                    let qualities = currentQualities
                    if !qualities.isEmpty {
                        let activeLabel = (selectedQualityByIndex[currentIndex] ?? qualities.first)?.label ?? "Авто"
                        Menu {
                            ForEach(qualities, id: \.label) { option in
                                Button {
                                    switchQuality(to: option)
                                } label: {
                                    if option.label == activeLabel {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        } label: {
                            Label(activeLabel, systemImage: "gearshape")
                                .font(.caption)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if let extUrl = currentItem.externalURL {
                    Button {
                        NSWorkspace.shared.open(extUrl)
                    } label: {
                        Label("В браузере", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
        }
        .padding(.bottom, 14)
    }

    private var currentQualities: [VideoQualityOption] {
        guard case .video(_, _, _, _, _, _, _, let qualities) = currentItem else { return [] }
        return resolvedStreams[currentIndex]?.qualities ?? qualities
    }

    @MainActor
    private func switchQuality(to option: VideoQualityOption) {
        let resumeTime = videoPlayer?.currentTime()
        selectedQualityByIndex[currentIndex] = option
        videoFallbackToWeb = false
        stopVideoPlayer()
        if let url = URL(string: option.url) {
            startAVPlayer(url: url, seekTo: resumeTime)
        }
    }

    @MainActor
    private func syncVideoPlayer() {
        stopVideoPlayer()
        videoFallbackToWeb = false
        isResolvingVideo = false

        guard case .video(let id, let ownerId, let accessKey, _, let streamUrl, let playerUrl, _, _) = currentItem else {
            return
        }

        let effectiveStream = selectedQualityByIndex[currentIndex]?.url ?? resolvedStreams[currentIndex]?.streamUrl ?? streamUrl
        let effectivePlayer = resolvedStreams[currentIndex]?.playerUrl ?? playerUrl

        if let s = effectiveStream, let url = URL(string: s) {
            startAVPlayer(url: url, seekTo: nil)
            return
        }

        if effectivePlayer == nil, id != 0, let resolver = PhotoViewerWindow.shared.videoResolver {
            let idx = currentIndex
            isResolvingVideo = true
            Task {
                let resolved = await resolver(ownerId, id, accessKey)
                await MainActor.run {
                    isResolvingVideo = false
                    if let resolved {
                        resolvedStreams[idx] = (resolved.streamUrl, resolved.playerUrl, resolved.qualities)
                        if idx == currentIndex, let s = resolved.streamUrl, let url = URL(string: s) {
                            startAVPlayer(url: url, seekTo: nil)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func startAVPlayer(url: URL, seekTo: CMTime?) {
        let headers = [
            "User-Agent": "VKAndroidApp/8.44-18440 (Android 13; SDK 33; arm64-v8a; Pixel 7; ru)"
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        videoStatusObservation = item.observe(\.status, options: [.new]) { observedItem, _ in
            if observedItem.status == .failed {
                Task { @MainActor in
                    stopVideoPlayer()
                    videoFallbackToWeb = true
                }
            }
        }
        let player = AVPlayer(playerItem: item)
        if let seekTo, seekTo.isValid && seekTo.seconds > 0 {
            player.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        videoPlayer = player
    }

    @MainActor
    private func stopVideoPlayer() {
        videoStatusObservation?.invalidate()
        videoStatusObservation = nil
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        videoPlayer = nil
    }

    private func selectIndex(_ idx: Int) {
        scale = 1.0
        saveStatus = nil
        currentIndex = idx
    }

    private func goPrevious() {
        guard currentIndex > 0 else { return }
        selectIndex(currentIndex - 1)
    }

    private func goNext() {
        guard currentIndex + 1 < items.count else { return }
        selectIndex(currentIndex + 1)
    }

    private func saveCurrentPhoto() {
        guard case .photo(let urlStr) = currentItem, let url = URL(string: urlStr) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent.isEmpty ? "photo.jpg" : url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: dest)
                await MainActor.run {
                    saveStatus = "Сохранено"
                }
            } catch {
                await MainActor.run {
                    saveStatus = "Ошибка"
                }
            }
        }
    }

    private func downloadVideo(url: URL, title: String) {
        let panel = NSSavePanel()
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "video" : safeTitle).mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        saveStatus = "Скачивание..."
        Task {
            do {
                let (tempUrl, _) = try await URLSession.shared.download(from: url)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempUrl, to: dest)
                await MainActor.run {
                    saveStatus = "Видео сохранено"
                }
            } catch {
                await MainActor.run {
                    saveStatus = "Ошибка скачивания"
                }
            }
        }
    }

    @MainActor
    private var mediaCommentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Комментарии").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { showCommentsDrawer = false } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if mediaComments.isEmpty {
                        Text("Нет комментариев")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mediaComments, id: \.id) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.authorName).font(.caption.bold()).foregroundStyle(.white)
                                Text(c.text).font(.caption).foregroundStyle(.white.opacity(0.9))
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            if case .video(let vid, let oid, _, _, _, _, _, _) = currentItem {
                HStack {
                    TextField("Комментарий...", text: $newCommentText)
                        .textFieldStyle(.roundedBorder)
                    Button("Отпр.") {
                        let txt = newCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !txt.isEmpty else { return }
                        newCommentText = ""
                        Task {
                            await PhotoViewerWindow.shared.mediaCommentCreator?(true, oid, vid, txt)
                            mediaComments = await PhotoViewerWindow.shared.mediaCommentsLoader?(true, oid, vid) ?? []
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.96))
    }
}

private struct TGVideoWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
    }
}
