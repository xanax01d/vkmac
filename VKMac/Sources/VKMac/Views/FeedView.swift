import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum FeedMediaFilter: String, CaseIterable {
    case all = "Все"
    case photo = "С фото"
    case video = "С видео"
    case audio = "С музыкой"
}

struct FeedView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showNewPostSheet: Bool = false
    @State private var newPostText: String = ""
    @State private var newPostPhotoPath: String? = nil
    @State private var schedulePost: Bool = false
    @State private var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State private var mediaFilter: FeedMediaFilter = .all
    @State private var sendToChatPost: FeedPost? = nil

    private var filteredPosts: [FeedPost] {
        let keywords = appState.mutedKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return appState.feedPosts.filter { post in
            if appState.hideAds && post.isAds { return false }
            if !keywords.isEmpty {
                let low = (post.text + " " + post.authorName).lowercased()
                if keywords.contains(where: { low.contains($0) }) { return false }
            }
            switch mediaFilter {
            case .all: break
            case .photo:
                if post.photos.isEmpty { return false }
            case .video:
                if !post.attachments.contains(where: { if case .video = $0 { return true }; return false }) { return false }
            case .audio:
                if !post.attachments.contains(where: { if case .audio = $0 { return true }; return false }) { return false }
            }
            return true
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                Picker("", selection: $mediaFilter) {
                    ForEach(FeedMediaFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                if !appState.stories.isEmpty {
                    StoriesBarView(stories: appState.stories)
                }

                ForEach(filteredPosts, id: \.postId) { post in
                    FeedPostCard(
                        post: post,
                        onLike: {
                            Task { await appState.toggleLike(post: post) }
                        },
                        onAuthorTap: {
                            appState.openOwnerPage(post.sourceId)
                        },
                        onCommentTap: {
                            appState.openPost(post)
                        },
                        onRepostTap: {
                            Task { await appState.repostPost(post: post) }
                        },
                        onBookmarkTap: {
                            Task { await appState.addBookmark(ownerId: post.sourceId, postId: post.postId) }
                        }
                    )
                    .contextMenu {
                        Button("Отправить в чат...") {
                            sendToChatPost = post
                        }
                        Button("Скрыть из ленты") {
                            Task { await appState.ignorePost(post) }
                        }
                    }
                }

                if appState.feedNextFrom != nil {
                    Button("Загрузить ещё") {
                        Task { await appState.loadFeed(reset: false) }
                    }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
        .navigationTitle("Лента")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showNewPostSheet = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Новая запись")

                Button {
                    Task { await appState.loadFeed(reset: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить ленту")
            }
        }
        .sheet(isPresented: $showNewPostSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Новая запись на стене")
                    .font(.headline)
                TextEditor(text: $newPostText)
                    .font(.body)
                    .frame(height: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                HStack {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            newPostPhotoPath = url.path
                        }
                    } label: {
                        Label(newPostPhotoPath == nil ? "Прикрепить фото" : URL(fileURLWithPath: newPostPhotoPath!).lastPathComponent, systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    if newPostPhotoPath != nil {
                        Button("Убрать") { newPostPhotoPath = nil }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                Toggle("Отложенная публикация", isOn: $schedulePost)
                if schedulePost {
                    DatePicker("Дата публикации", selection: $scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }
                HStack {
                    Spacer()
                    Button("Отмена") {
                        showNewPostSheet = false
                    }
                    Button(schedulePost ? "Запланировать" : "Опубликовать") {
                        let text = newPostText
                        let photo = newPostPhotoPath
                        let pubDate: Int64? = schedulePost ? Int64(scheduledDate.timeIntervalSince1970) : nil
                        newPostText = ""
                        newPostPhotoPath = nil
                        schedulePost = false
                        showNewPostSheet = false
                        Task { await appState.createPostWithPhoto(ownerId: 0, text: text, photoPath: photo, publishDate: pubDate) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newPostPhotoPath == nil)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .task {
            if appState.feedPosts.isEmpty {
                await appState.loadFeed(reset: true)
            }
        }
        .sheet(item: Binding<IdentifiableFeedPost?>(
            get: { sendToChatPost.map(IdentifiableFeedPost.init(post:)) },
            set: { if $0 == nil { sendToChatPost = nil } }
        )) { wrapped in
            SendPostToChatSheet(post: wrapped.post) { peerId in
                Task {
                    await appState.sendWallToPeer(peerId: peerId, ownerId: wrapped.post.sourceId, postId: wrapped.post.postId)
                }
                sendToChatPost = nil
            }
            .environmentObject(appState)
        }
    }
}

struct FeedPostCard: View {
    @EnvironmentObject private var appState: AppState
    let post: FeedPost
    let onLike: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    var onCommentTap: (() -> Void)? = nil
    var onRepostTap: (() -> Void)? = nil
    var onBookmarkTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onAuthorTap?()
            } label: {
                HStack(spacing: 10) {
                    AvatarView(urlString: post.authorAvatar, title: post.authorName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(formatDate(post.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if !post.text.isEmpty {
                Text(VkLinkHandler.linkify(post.text))
                    .font(.body)
                    .textSelection(.enabled)
            }

            if post.photos.count == 1, let url = URL(string: post.photos[0]) {
                Button {
                    let media = buildPostMedia(post)
                    PhotoViewerWindow.shared.showMedia(media, initialIndex: 0)
                } label: {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 320, height: 220)
                    }
                    .frame(maxWidth: 480, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else if post.photos.count > 1 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(post.photos.enumerated()), id: \.offset) { index, urlStr in
                        if let url = URL(string: urlStr) {
                            Button {
                                let media = buildPostMedia(post)
                                PhotoViewerWindow.shared.showMedia(media, initialIndex: index)
                            } label: {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.15))
                                }
                                .frame(height: 170)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !post.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(post.attachments.enumerated()), id: \.offset) { _, att in
                        postAttachmentView(att)
                    }
                }
            }

            HStack(spacing: 18) {
                Button(action: onLike) {
                    Label("\(post.likesCount)", systemImage: post.isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(post.isLiked ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)

                Button {
                    onCommentTap?()
                } label: {
                    Label("\(post.commentsCount)", systemImage: "bubble.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                if let onRepostTap {
                    Button(action: onRepostTap) {
                        Label("Поделиться", systemImage: "arrowshape.turn.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                if let onBookmarkTap {
                    Button(action: onBookmarkTap) {
                        Label("В закладки", systemImage: "bookmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            onCommentTap?()
        }
    }

    @MainActor
    @ViewBuilder
    private func postAttachmentView(_ attachment: Attachment) -> some View {
        switch attachment {
        case .photo(let urlStr, _, _):
            if let url = URL(string: urlStr) {
                Button {
                    PhotoViewerWindow.shared.show(urls: [urlStr], initialIndex: 0)
                } label: {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: 320, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        case .video(let vidId, let vidOwnerId, _, let title, let durationSec, let thumbUrl, let playerUrl, _, _):
            Button {
                let media = buildPostMedia(post)
                let idx = media.firstIndex { item in
                    if case .video(let i, let o, _, let t, _, let p, _, _) = item {
                        return (vidId != 0 && i == vidId && o == vidOwnerId) || (t == title && p == playerUrl)
                    }
                    return false
                } ?? 0
                PhotoViewerWindow.shared.showMedia(media, initialIndex: idx)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let thumbUrl, let url = URL(string: thumbUrl) {
                        ZStack {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color.secondary.opacity(0.15))
                            }
                            .frame(width: 300, height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    Label("\(title) (\(durationSec / 60):\(String(format: "%02d", durationSec % 60)))", systemImage: "play.rectangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        case .document(let title, let urlStr, let ext):
            if ext.lowercased() == "gif", let url = URL(string: urlStr) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("\(title) (GIF)", systemImage: "photo.on.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            } else if let url = URL(string: urlStr) {
                Link(destination: url) {
                    Label("\(title) (.\(ext))", systemImage: "doc")
                        .font(.caption)
                }
            } else {
                Label("\(title) (.\(ext))", systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .audio(let artist, let title, _, _):
            Label("\(artist) — \(title)", systemImage: "music.note")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .link(let title, let urlStr):
            if let url = URL(string: urlStr) {
                Link(destination: url) {
                    Label(title.isEmpty ? urlStr : title, systemImage: "link")
                        .font(.caption)
                }
            } else {
                Label(title.isEmpty ? urlStr : title, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .sticker(let urlStr):
            if let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 112, height: 112)
            }
        case .audioMessage(_, let durationSec, let transcript):
            VStack(alignment: .leading, spacing: 2) {
                Label("Голосовое сообщение (\(durationSec)с)", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
        case .poll(let pollId, let ownerId, let question, let answers):
            let totalVotes = answers.reduce(0) { $0 + $1.votes }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(appState.accentColor)
                    Text(question)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(totalVotes) голосов")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(answers, id: \.id) { ans in
                    let pct = totalVotes > 0 ? Double(ans.votes) * 100.0 / Double(totalVotes) : Double(ans.rate)
                    Button {
                        Task { await appState.votePoll(ownerId: ownerId, pollId: pollId, answerId: ans.id) }
                    } label: {
                        HStack {
                            Text(ans.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(Int(pct.rounded()))% (\(ans.votes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(appState.accentColor.opacity(0.16))
                                    .frame(width: max(0, geo.size.width * CGFloat(pct / 100.0)))
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .reply(_, let text):
            Text("↩ \(text)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .forwarded(let fromName, let text, _):
            Text("↪ \(fromName): \(text)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .botKeyboard:
            EmptyView()
        case .unknown(let kind):
            Text("[\(kind)]")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func buildPostMedia(_ post: FeedPost) -> [MediaViewerItem] {
        var items: [MediaViewerItem] = post.photos.map { .photo(url: $0) }
        for att in post.attachments {
            if case .video(let id, let ownerId, let accessKey, let title, _, let thumbUrl, let playerUrl, let streamUrl, let qualities) = att {
                items.append(.video(id: id, ownerId: ownerId, accessKey: accessKey, title: title, streamUrl: streamUrl, playerUrl: playerUrl, thumbnailUrl: thumbUrl, qualities: qualities))
            }
        }
        return items
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

struct StoriesBarView: View {
    @EnvironmentObject private var appState: AppState
    let stories: [StoryItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(stories, id: \.id) { story in
                    Button {
                        if story.isVideo, let videoUrl = story.mediaUrl, !videoUrl.isEmpty {
                            PhotoViewerWindow.shared.showMedia([
                                .video(
                                    id: story.id,
                                    ownerId: story.ownerId,
                                    accessKey: nil,
                                    title: story.authorName,
                                    streamUrl: videoUrl,
                                    playerUrl: nil,
                                    thumbnailUrl: story.previewUrl,
                                    qualities: []
                                )
                            ], initialIndex: 0)
                        } else if let photoUrl = story.mediaUrl ?? story.previewUrl, !photoUrl.isEmpty {
                            PhotoViewerWindow.shared.show(urls: [photoUrl], initialIndex: 0)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            AvatarView(urlString: story.authorAvatar ?? story.previewUrl, title: story.authorName, size: 52)
                                .overlay(
                                    Circle()
                                        .stroke(appState.accentColor, lineWidth: 2)
                                        .padding(-2)
                                )
                            Text(story.authorName)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}

private struct IdentifiableFeedPost: Identifiable {
    let post: FeedPost
    var id: String { "\(post.sourceId)_\(post.postId)" }
}

private struct SendPostToChatSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let post: FeedPost
    let onSelectPeer: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отправить запись в чат")
                    .font(.headline)
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
