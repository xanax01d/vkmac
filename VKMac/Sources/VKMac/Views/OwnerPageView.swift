import SwiftUI

private enum OwnerRelationKind: Identifiable {
    case friends(userId: Int64)
    case followers(userId: Int64)
    case members(groupId: Int64)
    case groups(userId: Int64)

    var id: String {
        switch self {
        case .friends(let id): return "friends_\(id)"
        case .followers(let id): return "followers_\(id)"
        case .members(let id): return "members_\(id)"
        case .groups(let id): return "groups_\(id)"
        }
    }

    var title: String {
        switch self {
        case .friends: return "Друзья"
        case .followers: return "Подписчики"
        case .members: return "Участники"
        case .groups: return "Группы"
        }
    }
}

struct OwnerPageView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var showStatusAlert: Bool = false
    @State private var newStatusText: String = ""
    let ownerId: Int64
    var onClose: (() -> Void)? = nil
    @State private var wallDraft: String = ""
    @State private var relationSheet: OwnerRelationKind?
    @State private var showPhotosSheet: Bool = false
    @State private var showAudioSheet: Bool = false
    @State private var friendsPreview: [OwnerSummary] = []
    @State private var groupsPreview: [OwnerSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            if let onClose {
                HStack {
                    Text(page?.isGroup == true ? "Сообщество" : "Профиль")
                        .font(.headline)
                    Spacer()
                    Button("Закрыть") {
                        onClose()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }

            if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection(page)
                        infoSection(page)
                        inlineFriendsAndGroupsSection(page)
                        wallSection(page)
                    }
                    .padding(16)
                }
            } else if appState.isOwnerPageLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка страницы...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Не удалось загрузить страницу")
                        .foregroundStyle(.secondary)
                    Button("Повторить") {
                        Task { await appState.loadOwnerPage(ownerId: ownerId) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ownerId) {
            await appState.loadOwnerPage(ownerId: ownerId)
            if ownerId > 0 {
                async let f = appState.fetchUserFriends(userId: ownerId)
                async let g = appState.fetchUserGroups(userId: ownerId)
                friendsPreview = await f
                groupsPreview = await g
            } else {
                friendsPreview = []
                groupsPreview = []
            }
        }
        .sheet(item: $relationSheet) { kind in
            OwnerRelationsSheet(kind: kind) { selectedId in
                relationSheet = nil
                appState.openOwnerPage(selectedId)
            } onClose: {
                relationSheet = nil
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showPhotosSheet) {
            OwnerPhotosSheet(ownerId: ownerId) {
                showPhotosSheet = false
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showAudioSheet) {
            OwnerAudioSheet(ownerId: ownerId) {
                showAudioSheet = false
            }
            .environmentObject(appState)
            .environmentObject(audioPlayer)
        }
        .alert("Изменить статус", isPresented: $showStatusAlert) {
            TextField("Новый статус", text: $newStatusText)
            Button("Сохранить") {
                let s = newStatusText
                Task { await appState.setStatus(s) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var page: OwnerPage? {
        appState.ownerPageCache[ownerId]
    }

    @ViewBuilder
    private func headerSection(_ page: OwnerPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = page.coverUrl, let url = URL(string: cover) {
                Button {
                    PhotoViewerWindow.shared.show(urls: [cover], initialIndex: 0)
                } label: {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                    }
                    .frame(height: 150)
                    .clipped()
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 14) {
                Button {
                    if let ava = page.avatarUrl {
                        PhotoViewerWindow.shared.show(urls: [ava], initialIndex: 0)
                    }
                } label: {
                    AvatarView(urlString: page.avatarUrl, title: page.name, size: 72)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(page.name)
                            .font(.title2.bold())
                        if page.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(appState.accentColor)
                        }
                        if !page.isGroup && page.online {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 9, height: 9)
                                .help("В сети")
                        }
                    }

                    if let screenName = page.screenName {
                        Text("@\(screenName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let status = page.status {
                        HStack(spacing: 6) {
                            Text(status)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !page.isGroup && page.id == appState.currentUser?.id {
                                Button {
                                    newStatusText = status
                                    showStatusAlert = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Изменить статус")
                            }
                        }
                    } else if !page.isGroup && page.id == appState.currentUser?.id {
                        Button("Установить статус") {
                            newStatusText = ""
                            showStatusAlert = true
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                Spacer()

                let isOwnPage = !page.isGroup && page.id == appState.currentUser?.id
                HStack(spacing: 8) {
                    if !isOwnPage {
                        Button {
                            Task { await appState.toggleMembership(page: page) }
                        } label: {
                            Text(membershipLabel(page))
                        }
                        .buttonStyle(.bordered)
                    }

                    if !page.isGroup && !isOwnPage {
                        let watched = appState.watchedOnlineIds.contains(page.id)
                        Button {
                            appState.toggleWatchOnline(userId: page.id)
                        } label: {
                            Image(systemName: watched ? "bell.fill" : "bell")
                        }
                        .buttonStyle(.bordered)
                        .help(watched ? "Отключить отслеживание онлайна" : "Отслеживать онлайн")

                        Button {
                            Task { await appState.banUser(page.id) }
                        } label: {
                            Image(systemName: "hand.raised")
                        }
                        .buttonStyle(.bordered)
                        .help("Заблокировать пользователя")
                    }

                    if !isOwnPage {
                        let wallWatched = appState.watchedWalls.contains(page.id)
                        Button {
                            appState.toggleWatchWall(page.id)
                        } label: {
                            Image(systemName: wallWatched ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.bordered)
                        .help(wallWatched ? "Отписаться от мониторинга постов" : "Мониторить новые посты")
                    }

                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "Скачать фото сюда"
                        if panel.runModal() == .OK, let folder = panel.url {
                            Task { _ = await appState.downloadAlbum(ownerId: page.id, destFolder: folder) }
                        }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .help("Скачать все фото альбома в папку")

                    if !page.isGroup {
                        Button {
                            appState.selectedPeerId = page.id
                            appState.selectedTab = .chats
                            onClose?()
                        } label: {
                            Label(
                                isOwnPage ? "Избранное" : "Написать",
                                systemImage: isOwnPage ? "bookmark.fill" : "message.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func infoSection(_ page: OwnerPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], alignment: .leading, spacing: 8) {
                if let friends = page.friendsCount {
                    ownerPillButton(
                        title: "Друзья (\(friends))",
                        icon: "person.crop.circle"
                    ) {
                        relationSheet = .friends(userId: page.id)
                    }
                }

                if let followers = page.followersCount {
                    ownerPillButton(
                        title: "\(followers) \(page.isGroup ? "участников" : "подписчиков")",
                        icon: "person.2"
                    ) {
                        relationSheet = page.isGroup
                            ? .members(groupId: page.id)
                            : .followers(userId: page.id)
                    }
                }

                ownerPillButton(
                    title: page.photosCount.map { "Фотографии (\($0))" } ?? "Фотографии",
                    icon: "photo.on.rectangle.angled"
                ) {
                    showPhotosSheet = true
                }

                ownerPillButton(
                    title: page.audiosCount.map { "Музыка (\($0))" } ?? "Музыка",
                    icon: "music.note.list"
                ) {
                    showAudioSheet = true
                }

                if !page.isGroup {
                    ownerPillButton(
                        title: page.groupsCount.map { "Группы (\($0))" } ?? "Группы",
                        icon: "rectangle.stack.person.crop"
                    ) {
                        relationSheet = .groups(userId: page.id)
                    }
                }
            }

            if page.city != nil || page.site != nil {
                HStack(spacing: 16) {
                    if let city = page.city {
                        Label(city, systemImage: "mappin.and.ellipse")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let site = page.site, let url = URL(string: site.hasPrefix("http") ? site : "https://\(site)") {
                        Link(destination: url) {
                            Label(site, systemImage: "link")
                                .font(.callout)
                        }
                    }
                }
            }

            if let description = page.description {
                Text(description)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func ownerPillButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inlineFriendsAndGroupsSection(_ page: OwnerPage) -> some View {
        if !page.isGroup {
            if !friendsPreview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Друзья")
                            .font(.headline)
                        Spacer()
                        Button("Все") {
                            relationSheet = .friends(userId: page.id)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(friendsPreview.prefix(15), id: \.id) { friend in
                                Button {
                                    appState.openOwnerPage(friend.id)
                                } label: {
                                    VStack(spacing: 5) {
                                        AvatarView(urlString: friend.avatarUrl, title: friend.name, size: 48)
                                        Text(friend.name.components(separatedBy: " ").first ?? friend.name)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 64)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !groupsPreview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Группы")
                            .font(.headline)
                        Spacer()
                        Button("Все") {
                            relationSheet = .groups(userId: page.id)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(groupsPreview.prefix(15), id: \.id) { group in
                                Button {
                                    appState.openOwnerPage(group.id)
                                } label: {
                                    VStack(spacing: 5) {
                                        AvatarView(urlString: group.avatarUrl, title: group.name, size: 48)
                                        Text(group.name)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 72)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func wallSection(_ page: OwnerPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Записи на стене")
                .font(.headline)

            if page.canPost {
                HStack(spacing: 8) {
                    TextField("Написать на стене...", text: $wallDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submitWallPost()
                        }
                    Button("Опубликовать") {
                        submitWallPost()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(wallDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if page.wallPosts.isEmpty {
                Text("Записей нет или стена скрыта настройками приватности")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(page.wallPosts, id: \.postId) { post in
                        FeedPostCard(
                            post: post,
                            onLike: {
                                Task {
                                    await appState.toggleLikeOnWall(ownerId: ownerId, post: post)
                                }
                            },
                            onAuthorTap: {
                                if post.sourceId != ownerId {
                                    appState.openOwnerPage(post.sourceId)
                                }
                            },
                            onCommentTap: {
                                appState.openPost(post)
                            },
                            onRepostTap: {
                                Task { await appState.repostPost(post: post) }
                            }
                        )
                    }
                }
            }
        }
    }

    private func membershipLabel(_ page: OwnerPage) -> String {
        if page.isGroup {
            return page.isMemberOrFriend ? "Вы в группе" : "Вступить"
        } else {
            return page.isMemberOrFriend ? "В друзьях" : "Добавить в друзья"
        }
    }

    private func submitWallPost() {
        let text = wallDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        wallDraft = ""
        Task {
            await appState.createPost(ownerId: ownerId, text: text)
        }
    }
}

private struct OwnerRelationsSheet: View {
    @EnvironmentObject private var appState: AppState
    let kind: OwnerRelationKind
    let onSelect: (Int64) -> Void
    let onClose: () -> Void

    @State private var items: [OwnerSummary] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title)
                    .font(.headline)
                Spacer()
                Button("Закрыть") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            TextField("Поиск...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                Text("Список пуст или скрыт настройками приватности")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredItems, id: \.id) { item in
                    Button {
                        onSelect(item.id)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(urlString: item.avatarUrl, title: item.name, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if item.isVerified {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(appState.accentColor)
                                    }
                                    if item.online {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 540)
        .task {
            isLoading = true
            switch kind {
            case .friends(let userId):
                items = await appState.fetchUserFriends(userId: userId)
            case .followers(let userId):
                items = await appState.fetchFollowers(userId: userId)
            case .members(let groupId):
                items = await appState.fetchGroupMembers(groupId: groupId)
            case .groups(let userId):
                items = await appState.fetchUserGroups(userId: userId)
            }
            isLoading = false
        }
    }

    private var filteredItems: [OwnerSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.lowercased().contains(q) ||
            ($0.screenName?.lowercased().contains(q) ?? false) ||
            ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }
}

private struct OwnerPhotosSheet: View {
    @EnvironmentObject private var appState: AppState
    let ownerId: Int64
    let onClose: () -> Void

    @State private var photos: [String] = []
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Фотографии")
                    .font(.headline)
                Spacer()
                Button("Закрыть") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty {
                Text("Фотографии отсутствуют или скрыты настройками приватности")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { idx, urlStr in
                            if let url = URL(string: urlStr) {
                                Button {
                                    PhotoViewerWindow.shared.show(urls: photos, initialIndex: idx)
                                } label: {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Rectangle().fill(Color.secondary.opacity(0.15))
                                    }
                                    .frame(height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 660, height: 540)
        .task {
            isLoading = true
            photos = await appState.fetchOwnerPhotos(ownerId: ownerId)
            isLoading = false
        }
    }
}

private struct OwnerAudioSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @State private var showStatusAlert: Bool = false
    @State private var newStatusText: String = ""
    let ownerId: Int64
    let onClose: () -> Void

    @State private var tracks: [AudioTrack] = []
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Музыка")
                    .font(.headline)
                Spacer()
                Button("Закрыть") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                Text("Аудиозаписи отсутствуют или скрыты настройками приватности")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tracks, id: \.id) { track in
                    let isCurrent = audioPlayer.currentTrack?.id == track.id && audioPlayer.currentTrack?.ownerId == track.ownerId
                    HStack(spacing: 12) {
                        Button {
                            if isCurrent {
                                audioPlayer.togglePlayPause()
                            } else {
                                audioPlayer.play(track: track, in: tracks)
                            }
                        } label: {
                            Image(systemName: isCurrent && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(isCurrent ? appState.accentColor : Color.primary)
                        }
                        .buttonStyle(.borderless)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.body.weight(isCurrent ? .semibold : .regular))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(String(format: "%d:%02d", track.durationSec / 60, track.durationSec % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 540)
        .task {
            isLoading = true
            tracks = await appState.fetchOwnerAudio(ownerId: ownerId)
            isLoading = false
        }
    }
}
