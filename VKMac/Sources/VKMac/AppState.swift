import Foundation
import SwiftUI
import AppKit
import LocalAuthentication
import UserNotifications

enum SidebarTab: String, CaseIterable, Identifiable {
    case myPage = "Моя страница"
    case chats = "Чаты"
    case feed = "Лента"
    case fave = "Закладки"
    case notifications = "Уведомления"
    case friends = "Друзья"
    case groups = "Группы"
    case videos = "Видео"
    case music = "Музыка"
    case search = "Поиск"
    case settings = "Настройки"
    case help = "Справка"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .myPage: return "person.crop.circle"
        case .chats: return "bubble.left.and.bubble.right"
        case .feed: return "newspaper"
        case .fave: return "bookmark"
        case .notifications: return "bell"
        case .friends: return "person.2"
        case .groups: return "rectangle.stack.person.crop"
        case .videos: return "play.rectangle"
        case .music: return "music.note.list"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}

private final class EventBridge: VkEventListener {
    private let handler: (VkEvent) -> Void

    init(handler: @escaping (VkEvent) -> Void) {
        self.handler = handler
    }

    func onEvent(event: VkEvent) {
        handler(event)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var authState: AuthState = .loggedOut
    @Published var selectedTab: SidebarTab = .chats
    @Published var currentUser: UserProfile?

    @Published var conversations: [ConversationItem] = []
    @Published var selectedPeerId: Int64?
    @Published var messagesByPeer: [Int64: [MessageItem]] = [:]
    @Published var typingByPeer: [Int64: Int64] = [:]

    @Published var feedPosts: [FeedPost] = []
    @Published var feedNextFrom: String?

    @Published var friends: [OwnerSummary] = []
    @Published var followers: [OwnerSummary] = []
    @Published var groups: [OwnerSummary] = []
    @Published var ownerPageCache: [Int64: OwnerPage] = [:]
    @Published var presentedOwnerId: Int64?
    @Published var isOwnerPageLoading: Bool = false

    @Published var presentedPost: FeedPost?
    @Published var commentsByPost: [String: [CommentItem]] = [:]
    @Published var notifications: [NotificationItem] = []
    @Published var videos: [VideoItem] = []
    @Published var playlists: [AudioPlaylist] = []
    @Published var searchUsersResult: [OwnerSummary] = []
    @Published var searchGroupsResult: [OwnerSummary] = []

    @Published var tracks: [AudioTrack] = []
    @Published var isLoading: Bool = false
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?

    @Published var oauthClientId: String = ""
    @Published var oauthClientSecret: String = ""
    @Published var cacheSizeBytes: UInt64 = 0

    // New wave features
    @Published var pinnedPeerIds: [Int64] = []
    @Published var stories: [StoryItem] = []
    @Published var faveItems: [FaveItem] = []
    @Published var listeningHistory: [AudioTrack] = []
    @Published var recommendedTracks: [AudioTrack] = []
    @Published var inactiveFriends: [OwnerSummary] = []

    @Published var stealthMode: Bool = false
    @Published var hideAds: Bool = false
    @Published var hideReposts: Bool = false
    @Published var mutedKeywords: String = ""
    @Published var compactMode: Bool = false
    @Published var accentChoice: String = "system"
    @Published var touchIdEnabled: Bool = false
    @Published var isLocked: Bool = false
    @Published var appMode: String = "all"
    @Published var showCommandPalette: Bool = false
    @Published var stickerPacks: [StickerPack] = []
    @Published var isLoadingStickers: Bool = false

    @Published var hideNotificationPreview: Bool = false
    @Published var dndEnabled: Bool = false
    @Published var dndStartHour: Int = 23
    @Published var dndEndHour: Int = 8
    @Published var autoLockOnMinimize: Bool = false
    @Published var infiniteWave: Bool = false
    @Published var snippets: [SnippetItem] = []
    @Published var birthdays: [BirthdayFriend] = []
    @Published var watchedOnlineIds: [Int64] = []
    @Published var topArtists: [ArtistStat] = []
    @Published var offlineAudioIds: Set<String> = []
    @Published var offlineTracks: [AudioTrack] = []
    @Published var crossfadeSeconds: Double = 0
    @Published var eqPreset: String = "Обычный"
    @Published var eqBands: [Float] = [0, 0, 0, 0, 0]
    @Published var friendRequests: [FriendRequestItem] = []
    @Published var bannedUsers: [OwnerSummary] = []
    @Published var savedAccounts: [AccountSummary] = []
    @Published var watchedWalls: [Int64] = []
    @Published var archivedPeerIds: [Int64] = []
    @Published var pinnedMessageByPeer: [Int64: MessageItem] = [:]
    @Published var favePages: [OwnerSummary] = []

    var totalUnreadCount: UInt32 {
        conversations.reduce(0) { $0 + ($1.isMuted ? 0 : $1.unreadCount) }
    }

    var accentColor: Color {
        switch accentChoice {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        default: return .accentColor
        }
    }

    private var client: VkClient?
    private var eventBridge: EventBridge?
    private var typingClearTasks: [Int64: Task<Void, Never>] = [:]

    func bootstrap() async {
        guard client == nil else { return }
        do {
            let vkClient = try VkClient(dataDir: "")
            self.client = vkClient

            PhotoViewerWindow.shared.videoResolver = { [weak self] ownerId, videoId, accessKey in
                await self?.resolveVideo(ownerId: ownerId, videoId: videoId, accessKey: accessKey)
            }
            PhotoViewerWindow.shared.mediaCommentsLoader = { [weak self] isVideo, ownerId, itemId in
                await self?.getMediaComments(isVideo: isVideo, ownerId: ownerId, itemId: itemId) ?? []
            }
            PhotoViewerWindow.shared.mediaCommentCreator = { [weak self] isVideo, ownerId, itemId, text in
                await self?.createMediaComment(isVideo: isVideo, ownerId: ownerId, itemId: itemId, text: text)
            }

            let cfg = vkClient.getOauthConfig()
            self.oauthClientId = cfg.clientId
            self.oauthClientSecret = cfg.clientSecret
            self.cacheSizeBytes = (try? vkClient.getCacheSizeBytes()) ?? 0

            loadPrefs()
            if touchIdEnabled {
                isLocked = true
            }
            AudioPlayerService.shared.onTrackStarted = { [weak self] track in
                Task { @MainActor [weak self] in
                    self?.recordTrackPlay(track)
                }
            }
            AudioPlayerService.shared.localURLResolver = { [weak self] track in
                self?.offlineAudioURL(for: track)
            }
            AudioPlayerService.shared.onQueueEnded = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.infiniteWave else { return }
                    await self.loadRecommendations()
                    if !self.recommendedTracks.isEmpty {
                        AudioPlayerService.shared.appendAndPlayNext(self.recommendedTracks)
                    }
                }
            }
            requestNotificationPermission()

            let bridge = EventBridge { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleEvent(event)
                }
            }
            self.eventBridge = bridge
            await vkClient.subscribeEvents(listener: bridge)

            let restored = await vkClient.restoreSession()
            self.authState = restored
            if case .authenticated = restored {
                await loadInitialData()
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func loginPassword(
        login: String,
        password: String,
        code2fa: String? = nil,
        captchaSid: String? = nil,
        captchaKey: String? = nil
    ) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let state = try await client.loginPassword(
                login: login,
                password: password,
                code2fa: code2fa,
                captchaSid: captchaSid,
                captchaKey: captchaKey
            )
            self.authState = state
            if case .authenticated = state {
                await loadInitialData()
            }
        } catch {
            self.errorMessage = formatVkError(error)
        }
    }

    func loginWithRedirectUrl(_ url: String) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let state = try await client.loginWithRedirectUrl(url: url)
            self.authState = state
            if case .authenticated = state {
                await loadInitialData()
            }
        } catch {
            self.errorMessage = formatVkError(error)
        }
    }

    func loginWithToken(_ tokenOrUrl: String) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let state = try await client.loginWithToken(tokenOrUrl: tokenOrUrl)
            self.authState = state
            if case .authenticated = state {
                await loadInitialData()
            }
        } catch {
            self.errorMessage = formatVkError(error)
        }
    }

    func request2faSms() async -> Bool {
        guard let client else { return false }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await client.request2faSms()
            return true
        } catch {
            self.errorMessage = formatVkError(error)
            return false
        }
    }

    func oauthAuthorizeUrl() -> URL? {
        guard let client else { return nil }
        return URL(string: client.getOauthAuthorizeUrl())
    }

    func logout() async {
        guard let client else { return }
        do {
            try await client.logout()
            authState = .loggedOut
            currentUser = nil
            conversations = []
            messagesByPeer = [:]
            feedPosts = []
            feedNextFrom = nil
            tracks = []
            selectedPeerId = nil
            isConnected = false
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadInitialData() async {
        await refreshCurrentUser()
        if let u = currentUser, let client {
            let fullName = "\(u.firstName) \(u.lastName)".trimmingCharacters(in: .whitespacesAndNewlines)
            try? client.saveAccountMetadata(userId: u.id, name: fullName, avatarUrl: u.avatarUrl)
            loadSavedAccounts()
        }
        loadPinnedPeers()
        loadArchivedPeers()
        loadWatchedWalls()
        await loadConversations()
        await loadStories()
        await loadFriendRequests()
        refreshCacheSize()
    }

    func refreshCurrentUser() async {
        guard let client else { return }
        if let user = try? await client.getCurrentUser() {
            currentUser = user
        }
    }

    func loadConversations() async {
        guard let client else { return }
        if let cached = try? client.getCachedConversations(offset: 0, count: 50), !cached.isEmpty {
            conversations = cached
            if selectedPeerId == nil {
                selectedPeerId = cached.first?.peerId
            }
        }
        do {
            let fresh = try await client.getConversations(offset: 0, count: 50)
            conversations = fresh
            if selectedPeerId == nil {
                selectedPeerId = fresh.first?.peerId
            }
            updateDockBadge()
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadMessages(peerId: Int64) async {
        guard let client else { return }
        if let cached = try? client.getCachedMessages(peerId: peerId, offset: 0, count: 50), !cached.isEmpty {
            messagesByPeer[peerId] = cached.sorted { $0.date < $1.date }
        }
        do {
            let fresh = try await client.getMessages(peerId: peerId, offset: 0, count: 50)
            messagesByPeer[peerId] = fresh.sorted { $0.date < $1.date }
            if peerId < 0, let kb = try? await client.getConversationKeyboard(peerId: peerId) {
                conversationKeyboards[peerId] = kb
            }
            if let idx = conversations.firstIndex(where: { $0.peerId == peerId }) {
                let c = conversations[idx]
                conversations[idx] = ConversationItem(
                    peerId: c.peerId,
                    title: c.title,
                    avatarUrl: c.avatarUrl,
                    lastMessageText: c.lastMessageText,
                    lastMessageDate: c.lastMessageDate,
                    unreadCount: 0,
                    isMuted: c.isMuted
                )
            }
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func sendMessage(peerId: Int64, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        do {
            let sent = try await client.sendMessage(peerId: peerId, text: trimmed)
            appendOrUpdateMessage(sent)
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadFeed(reset: Bool = false) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        let startFrom = reset ? nil : feedNextFrom
        do {
            let page = try await client.getNewsfeed(startFrom: startFrom)
            if reset {
                feedPosts = page.items
            } else {
                let existingIds = Set(feedPosts.map { "\($0.sourceId)_\($0.postId)" })
                let newItems = page.items.filter { !existingIds.contains("\($0.sourceId)_\($0.postId)") }
                feedPosts.append(contentsOf: newItems)
            }
            feedNextFrom = page.nextFrom
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func toggleLike(post: FeedPost) async {
        guard let client else { return }
        do {
            let newCount: UInt32
            let newLiked: Bool
            if post.isLiked {
                newCount = try await client.unlikePost(ownerId: post.sourceId, postId: post.postId)
                newLiked = false
            } else {
                newCount = try await client.likePost(ownerId: post.sourceId, postId: post.postId)
                newLiked = true
            }
            if let idx = feedPosts.firstIndex(where: { $0.postId == post.postId && $0.sourceId == post.sourceId }) {
                let old = feedPosts[idx]
                feedPosts[idx] = FeedPost(
                    postId: old.postId,
                    sourceId: old.sourceId,
                    authorName: old.authorName,
                    authorAvatar: old.authorAvatar,
                    date: old.date,
                    text: old.text,
                    photos: old.photos,
                    attachments: old.attachments,
                    likesCount: newCount,
                    isLiked: newLiked,
                    commentsCount: old.commentsCount,
                    isAds: old.isAds
                )
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func openOwnerPage(_ ownerId: Int64) {
        presentedOwnerId = ownerId
    }

    func loadOwnerPage(ownerId: Int64) async {
        guard let client else { return }
        isOwnerPageLoading = true
        defer { isOwnerPageLoading = false }
        do {
            let page = try await client.getOwnerPage(ownerId: ownerId, wallCount: 20)
            ownerPageCache[ownerId] = page
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadFriends() async {
        guard let client else { return }
        do {
            friends = try await client.getFriends(count: 200)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadMyFollowers() async {
        guard let client else { return }
        do {
            followers = try await client.getFollowers(userId: 0, count: 200)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func fetchUserFriends(userId: Int64) async -> [OwnerSummary] {
        guard let client else { return [] }
        do {
            return try await client.getUserFriends(userId: userId, count: 200)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func fetchFollowers(userId: Int64) async -> [OwnerSummary] {
        guard let client else { return [] }
        do {
            return try await client.getFollowers(userId: userId, count: 200)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func fetchGroupMembers(groupId: Int64) async -> [OwnerSummary] {
        guard let client else { return [] }
        do {
            return try await client.getGroupMembers(groupId: groupId, count: 200)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func fetchUserGroups(userId: Int64) async -> [OwnerSummary] {
        guard let client else { return [] }
        do {
            return try await client.getUserGroups(userId: userId, count: 200)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func fetchOwnerPhotos(ownerId: Int64) async -> [String] {
        guard let client else { return [] }
        do {
            return try await client.getOwnerPhotos(ownerId: ownerId, count: 100)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func fetchOwnerAudio(ownerId: Int64) async -> [AudioTrack] {
        guard let client else { return [] }
        do {
            return try await client.getOwnerAudio(ownerId: ownerId, count: 100)
        } catch {
            errorMessage = formatVkError(error)
            return []
        }
    }

    func loadGroups() async {
        guard let client else { return }
        do {
            groups = try await client.getGroups(count: 200)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func toggleLikeOnWall(ownerId: Int64, post: FeedPost) async {
        guard let client else { return }
        do {
            let newCount: UInt32
            let newLiked: Bool
            if post.isLiked {
                newCount = try await client.unlikePost(ownerId: post.sourceId, postId: post.postId)
                newLiked = false
            } else {
                newCount = try await client.likePost(ownerId: post.sourceId, postId: post.postId)
                newLiked = true
            }
            if let page = ownerPageCache[ownerId],
               let idx = page.wallPosts.firstIndex(where: { $0.postId == post.postId && $0.sourceId == post.sourceId }) {
                var updatedPosts = page.wallPosts
                let old = updatedPosts[idx]
                updatedPosts[idx] = FeedPost(
                    postId: old.postId,
                    sourceId: old.sourceId,
                    authorName: old.authorName,
                    authorAvatar: old.authorAvatar,
                    date: old.date,
                    text: old.text,
                    photos: old.photos,
                    attachments: old.attachments,
                    likesCount: newCount,
                    isLiked: newLiked,
                    commentsCount: old.commentsCount,
                    isAds: old.isAds
                )
                ownerPageCache[ownerId] = OwnerPage(
                    id: page.id,
                    isGroup: page.isGroup,
                    name: page.name,
                    screenName: page.screenName,
                    avatarUrl: page.avatarUrl,
                    coverUrl: page.coverUrl,
                    status: page.status,
                    description: page.description,
                    followersCount: page.followersCount,
                    friendsCount: page.friendsCount,
                    photosCount: page.photosCount,
                    audiosCount: page.audiosCount,
                    groupsCount: page.groupsCount,
                    online: page.online,
                    city: page.city,
                    site: page.site,
                    isVerified: page.isVerified,
                    isMemberOrFriend: page.isMemberOrFriend,
                    canPost: page.canPost,
                    wallPosts: updatedPosts
                )
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func openPost(_ post: FeedPost) {
        presentedPost = post
    }

    func loadComments(ownerId: Int64, postId: Int64) async {
        guard let client else { return }
        let key = "\(ownerId)_\(postId)"
        do {
            let items = try await client.getPostComments(ownerId: ownerId, postId: postId, offset: 0, count: 50)
            commentsByPost[key] = items
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func createComment(ownerId: Int64, postId: Int64, text: String) async {
        guard let client else { return }
        do {
            _ = try await client.createComment(ownerId: ownerId, postId: postId, message: text)
            await loadComments(ownerId: ownerId, postId: postId)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func createPost(ownerId: Int64, text: String) async {
        guard let client else { return }
        do {
            _ = try await client.createPost(ownerId: ownerId, message: text)
            if ownerId != 0 {
                await loadOwnerPage(ownerId: ownerId)
            }
            await loadFeed(reset: true)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func repostPost(post: FeedPost) async {
        guard let client else { return }
        do {
            try await client.repostPost(ownerId: post.sourceId, postId: post.postId, message: nil)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func toggleMembership(page: OwnerPage) async {
        guard let client else { return }
        do {
            if page.isGroup {
                if page.isMemberOrFriend {
                    try await client.leaveGroup(groupId: page.id)
                } else {
                    try await client.joinGroup(groupId: page.id)
                }
            } else {
                if page.isMemberOrFriend {
                    try await client.removeFriend(userId: page.id)
                } else {
                    try await client.addFriend(userId: page.id)
                }
            }
            await loadOwnerPage(ownerId: page.id)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadNotifications() async {
        guard let client else { return }
        do {
            notifications = try await client.getNotifications(count: 50)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadVideos() async {
        guard let client else { return }
        do {
            videos = try await client.getVideos(ownerId: nil, count: 40)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func searchVideos(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return }
        if trimmed.isEmpty {
            await loadVideos()
            return
        }
        do {
            videos = try await client.searchVideos(query: trimmed, count: 40)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func resolveVideo(ownerId: Int64, videoId: Int64, accessKey: String?) async -> VideoItem? {
        guard let client else { return nil }
        return try? await client.resolveVideo(ownerId: ownerId, videoId: videoId, accessKey: accessKey)
    }

    func performGlobalSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        do {
            async let users = client.searchUsers(query: trimmed, count: 30)
            async let groups = client.searchGroups(query: trimmed, count: 30)
            searchUsersResult = try await users
            searchGroupsResult = try await groups
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadPlaylists() async {
        guard let client else { return }
        do {
            playlists = try await client.getAudioPlaylists(ownerId: nil, count: 50)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadPlaylistTracks(_ playlist: AudioPlaylist) async {
        guard let client else { return }
        do {
            tracks = try await client.getPlaylistAudio(ownerId: playlist.ownerId, albumId: playlist.id, count: 100)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func sendMessageWithOptions(peerId: Int64, text: String, replyTo: Int64?, photoPath: String?) async {
        guard let client else { return }
        do {
            let sent = try await client.sendMessageWithOptions(
                peerId: peerId,
                text: text,
                replyTo: replyTo,
                photoPath: photoPath
            )
            appendOrUpdateMessage(sent)
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func deleteMessage(peerId: Int64, messageId: Int64) async {
        guard let client else { return }
        do {
            try await client.deleteMessage(messageId: messageId)
            messagesByPeer[peerId]?.removeAll { $0.id == messageId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func editMessage(peerId: Int64, messageId: Int64, text: String) async {
        guard let client else { return }
        do {
            try await client.editMessage(peerId: peerId, messageId: messageId, text: text)
            await loadMessages(peerId: peerId)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func markAsRead(peerId: Int64) async {
        guard let client, !stealthMode else { return }
        try? await client.markAsRead(peerId: peerId)
    }

    func loadAudio() async {
        guard let client else { return }
        if let cached = try? client.getCachedAudio(offset: 0, count: 100), !cached.isEmpty {
            tracks = cached
        }
        do {
            let fresh = try await client.getAudio(offset: 0, count: 100)
            tracks = fresh
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func searchAudio(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return }
        if trimmed.isEmpty {
            await loadAudio()
            return
        }
        do {
            tracks = try await client.searchAudio(query: trimmed)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func saveOAuthConfig() {
        guard let client else { return }
        do {
            try client.setOauthConfig(clientId: oauthClientId, clientSecret: oauthClientSecret)
            errorMessage = nil
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func clearCache() {
        guard let client else { return }
        do {
            try client.clearCache()
            conversations = []
            messagesByPeer = [:]
            tracks = []
            refreshCacheSize()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func refreshCacheSize() {
        guard let client else { return }
        cacheSizeBytes = (try? client.getCacheSizeBytes()) ?? 0
    }

    private func handleEvent(_ event: VkEvent) {
        switch event {
        case .newMessage(let message):
            appendOrUpdateMessage(message)
            updateConversationOnNewMessage(message)
            updateDockBadge()
            if !message.isOut {
                postLocalNotification(for: message)
            }
            if message.peerId == selectedPeerId || message.peerId < 0 || !message.attachments.isEmpty {
                let targetPeer = message.peerId
                Task { @MainActor [weak self] in
                    await self?.refreshRecentMessages(peerId: targetPeer)
                }
            }
        case .messageEdited(let message):
            appendOrUpdateMessage(message)
        case .readIncoming(let peerId, _):
            if let idx = conversations.firstIndex(where: { $0.peerId == peerId }) {
                let c = conversations[idx]
                conversations[idx] = ConversationItem(
                    peerId: c.peerId,
                    title: c.title,
                    avatarUrl: c.avatarUrl,
                    lastMessageText: c.lastMessageText,
                    lastMessageDate: c.lastMessageDate,
                    unreadCount: 0,
                    isMuted: c.isMuted
                )
            }
            updateDockBadge()
        case .readOutgoing:
            break
        case .typing(let peerId, let userId):
            typingByPeer[peerId] = userId
            typingClearTasks[peerId]?.cancel()
            typingClearTasks[peerId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.typingByPeer.removeValue(forKey: peerId)
            }
        case .connectionStatus(let connected):
            isConnected = connected
        }
    }

    private func refreshRecentMessages(peerId: Int64) async {
        guard let client else { return }
        guard let fresh = try? await client.getMessages(peerId: peerId, offset: 0, count: 25), !fresh.isEmpty else {
            return
        }
        var existing = messagesByPeer[peerId] ?? []
        for msg in fresh {
            if let idx = existing.firstIndex(where: { $0.id == msg.id }) {
                existing[idx] = msg
            } else {
                existing.append(msg)
            }
        }
        existing.sort { $0.date < $1.date }
        messagesByPeer[peerId] = existing
        if peerId < 0, let kb = try? await client.getConversationKeyboard(peerId: peerId) {
            conversationKeyboards[peerId] = kb
        }
    }

    private func appendOrUpdateMessage(_ message: MessageItem) {
        var list = messagesByPeer[message.peerId] ?? []
        if let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx] = message
        } else {
            list.append(message)
            list.sort { $0.date < $1.date }
        }
        messagesByPeer[message.peerId] = list
    }

    private func updateConversationOnNewMessage(_ message: MessageItem) {
        let preview = message.text.isEmpty ? "[Вложение]" : message.text
        if let idx = conversations.firstIndex(where: { $0.peerId == message.peerId }) {
            let old = conversations[idx]
            let unread = (selectedPeerId == message.peerId || message.isOut) ? old.unreadCount : old.unreadCount + 1
            let updated = ConversationItem(
                peerId: old.peerId,
                title: old.title,
                avatarUrl: old.avatarUrl,
                lastMessageText: preview,
                lastMessageDate: message.date,
                unreadCount: unread,
                isMuted: old.isMuted
            )
            conversations.remove(at: idx)
            conversations.insert(updated, at: 0)
        } else {
            Task { await loadConversations() }
        }
    }

    private func formatVkError(_ error: Error) -> String {
        if let vkErr = error as? VkError {
            switch vkErr {
            case .InvalidToken:
                return "Токен недействителен или истёк — войдите заново в Настройках"
            case .ValidationRequired(let validationType, let phoneMask):
                return "Требуется 2FA (\(validationType)) \(phoneMask)"
            case .CaptchaRequired(let sid, _):
                return "Требуется капча (sid: \(sid))"
            case .ApiError(let code, let message):
                return "Ошибка VK API \(code): \(message)"
            case .Network(let details):
                return "Ошибка сети: \(details)"
            case .Storage(let details):
                return "Ошибка кэша SQLite: \(details)"
            case .Keychain(let details):
                return "Ошибка Keychain: \(details)"
            case .InvalidInput(let details):
                return "Некорректные данные: \(details)"
            case .RateLimited:
                return "Слишком много запросов к VK API, подождите секунду"
            case .Internal(let details):
                return "Внутренняя ошибка: \(details)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - System, Prefs & Security

    func isInQuietHours() -> Bool {
        guard dndEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        if dndStartHour == dndEndHour { return false }
        if dndStartHour < dndEndHour {
            return hour >= dndStartHour && hour < dndEndHour
        } else {
            return hour >= dndStartHour || hour < dndEndHour
        }
    }

    func updateDockBadge() {
        if isInQuietHours() {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = totalUnreadCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Ответить",
            options: [],
            textInputButtonTitle: "Отправить",
            textInputPlaceholder: "Сообщение..."
        )
        let category = UNNotificationCategory(
            identifier: "VK_MSG_CAT",
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func postLocalNotification(for message: MessageItem) {
        if isInQuietHours() { return }
        let conv = conversations.first(where: { $0.peerId == message.peerId })
        if conv?.isMuted == true { return }
        if NSApp.isActive && selectedTab == .chats && selectedPeerId == message.peerId { return }

        let content = UNMutableNotificationContent()
        if hideNotificationPreview {
            content.title = "ВКонтакте"
            content.body = "Новое сообщение"
        } else {
            content.title = conv?.title ?? "ВКонтакте"
            content.body = message.text.isEmpty ? "Новое вложение" : message.text
        }
        content.sound = .default
        content.categoryIdentifier = "VK_MSG_CAT"
        content.userInfo = ["peerId": message.peerId]

        let req = UNNotificationRequest(
            identifier: "vk-msg-\(message.peerId)-\(message.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func loadPrefs() {
        guard let client else { return }
        stealthMode = (try? client.getPref(key: "stealthMode")) == "1"
        hideAds = (try? client.getPref(key: "hideAds")) == "1"
        hideReposts = (try? client.getPref(key: "hideReposts")) == "1"
        mutedKeywords = (try? client.getPref(key: "mutedKeywords")) ?? ""
        compactMode = (try? client.getPref(key: "compactMode")) == "1"
        accentChoice = (try? client.getPref(key: "accentChoice")) ?? "system"
        touchIdEnabled = (try? client.getPref(key: "touchIdEnabled")) == "1"
        appMode = (try? client.getPref(key: "appMode")) ?? "all"
        hideNotificationPreview = (try? client.getPref(key: "hideNotificationPreview")) == "1"
        dndEnabled = (try? client.getPref(key: "dndEnabled")) == "1"
        if let s = try? client.getPref(key: "dndStartHour"), let v = Int(s) { dndStartHour = v }
        if let e = try? client.getPref(key: "dndEndHour"), let v = Int(e) { dndEndHour = v }
        autoLockOnMinimize = (try? client.getPref(key: "autoLockOnMinimize")) == "1"
        infiniteWave = (try? client.getPref(key: "infiniteWave")) == "1"
        if let cf = try? client.getPref(key: "crossfadeSeconds"), let v = Double(cf) {
            crossfadeSeconds = v
            AudioPlayerService.shared.crossfadeSeconds = v
        }
        loadSnippets()
        loadWatchedOnline()
        refreshOfflineAudioList()
    }

    func savePref(key: String, value: String) {
        guard let client else { return }
        try? client.setPref(key: key, value: value)
    }

    func unlockWithTouchID() {
        let context = LAContext()
        var err: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics
        context.evaluatePolicy(policy, localizedReason: "Разблокировать VKMac") { [weak self] success, _ in
            Task { @MainActor [weak self] in
                if success {
                    self?.isLocked = false
                }
            }
        }
    }

    // MARK: - Pins & Drafts

    func loadPinnedPeers() {
        guard let client else { return }
        pinnedPeerIds = (try? client.getPinnedPeers()) ?? []
    }

    func togglePin(peerId: Int64) {
        guard let client else { return }
        _ = try? client.togglePinConversation(peerId: peerId)
        loadPinnedPeers()
    }

    func saveDraft(peerId: Int64, text: String) {
        guard let client else { return }
        try? client.saveDraft(peerId: peerId, text: text)
    }

    func loadDraft(peerId: Int64) -> String {
        guard let client else { return "" }
        return (try? client.getDraft(peerId: peerId)) ?? ""
    }

    // MARK: - Stories, Fave, Polls, Scheduled Posts

    func loadStories() async {
        guard let client else { return }
        if let items = try? await client.getStories() {
            stories = items
        }
    }

    func loadFave() async {
        guard let client else { return }
        do {
            faveItems = try await client.getFave(count: 50)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func addBookmark(ownerId: Int64, postId: Int64) async {
        guard let client else { return }
        do {
            try await client.faveAddPost(ownerId: ownerId, postId: postId)
            await loadFave()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func removeBookmark(ownerId: Int64, postId: Int64) async {
        guard let client else { return }
        do {
            try await client.faveRemovePost(ownerId: ownerId, postId: postId)
            faveItems.removeAll { $0.post?.postId == postId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func votePoll(ownerId: Int64, pollId: Int64, answerId: Int64) async {
        guard let client else { return }
        do {
            try await client.votePoll(ownerId: ownerId, pollId: pollId, answerId: answerId)
            await loadFeed(reset: true)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func createPostScheduled(ownerId: Int64, text: String, publishDate: Int64?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty else { return }
        do {
            _ = try await client.createPostScheduled(ownerId: ownerId, message: trimmed, publishDate: publishDate)
            await loadFeed(reset: true)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    // MARK: - Advanced Chats (Docs, Voice, Stickers, Forward, Reactions, Search, Info, Export, Presence)

    func sendDocMessage(peerId: Int64, filePath: String, text: String = "", isAudioMessage: Bool = false) async {
        guard let client else { return }
        do {
            let msg = try await client.sendDocMessage(peerId: peerId, filePath: filePath, text: text, isAudioMessage: isAudioMessage)
            appendOrUpdateMessage(msg)
            updateConversationOnNewMessage(msg)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func forwardMessages(peerId: Int64, messageIds: [Int64], text: String = "") async {
        guard let client, !messageIds.isEmpty else { return }
        do {
            let msg = try await client.forwardMessages(peerId: peerId, messageIds: messageIds, text: text)
            appendOrUpdateMessage(msg)
            updateConversationOnNewMessage(msg)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func sendSticker(peerId: Int64, stickerId: Int64) async {
        guard let client else { return }
        do {
            let msg = try await client.sendSticker(peerId: peerId, stickerId: stickerId)
            appendOrUpdateMessage(msg)
            updateConversationOnNewMessage(msg)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func sendAudioAttachment(peerId: Int64, ownerId: Int64, audioId: Int64, text: String = "") async {
        guard let client else { return }
        do {
            let msg = try await client.sendAudioMessageAttachment(peerId: peerId, ownerId: ownerId, audioId: audioId, text: text)
            appendOrUpdateMessage(msg)
            updateConversationOnNewMessage(msg)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func sendReaction(peerId: Int64, messageId: Int64, reactionId: UInt32) async {
        guard let client else { return }
        do {
            try await client.sendReaction(peerId: peerId, messageId: messageId, reactionId: reactionId)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func searchMessages(peerId: Int64?, query: String) async -> [MessageItem] {
        guard let client else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let remote = try? await client.searchMessages(peerId: peerId, query: trimmed, count: 30), !remote.isEmpty {
            return remote
        }
        return (try? client.searchCachedMessages(query: trimmed, limit: 30)) ?? []
    }

    func getChatMembers(peerId: Int64) async -> [ChatMember] {
        guard let client else { return [] }
        return (try? await client.getChatMembers(peerId: peerId)) ?? []
    }

    func setChatTitle(peerId: Int64, title: String) async {
        guard let client else { return }
        do {
            try await client.setChatTitle(peerId: peerId, title: title)
            await loadConversations()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func pinMessage(peerId: Int64, messageId: Int64) async {
        guard let client else { return }
        do {
            try await client.pinMessage(peerId: peerId, messageId: messageId)
            if let msg = messagesByPeer[peerId]?.first(where: { $0.id == messageId }) {
                pinnedMessageByPeer[peerId] = msg
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func getUserPresence(userId: Int64) async -> UserPresence? {
        guard let client else { return nil }
        return try? await client.getUserPresence(userId: userId)
    }

    func exportChatHistory(peerId: Int64, destPath: String) -> UInt32 {
        guard let client else { return 0 }
        do {
            return try client.exportChatHistory(peerId: peerId, destPath: destPath)
        } catch {
            errorMessage = formatVkError(error)
            return 0
        }
    }

    // MARK: - Advanced Music & Cleanup

    func recordTrackPlay(_ track: AudioTrack) {
        guard let client else { return }
        try? client.recordTrackPlay(track: track)
        loadListeningHistory()
    }

    func loadListeningHistory() {
        guard let client else { return }
        listeningHistory = (try? client.getListeningHistory(limit: 100)) ?? []
    }

    func loadRecommendations() async {
        guard let client else { return }
        do {
            recommendedTracks = try await client.getAudioRecommendations(count: 50)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func addAudio(ownerId: Int64, audioId: Int64) async {
        guard let client else { return }
        do {
            _ = try await client.addAudio(ownerId: ownerId, audioId: audioId)
            await loadAudio()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func deleteAudio(ownerId: Int64, audioId: Int64) async {
        guard let client else { return }
        do {
            try await client.deleteAudio(ownerId: ownerId, audioId: audioId)
            tracks.removeAll { $0.id == audioId && $0.ownerId == ownerId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func setBroadcast(ownerId: Int64, audioId: Int64) async {
        guard let client else { return }
        do {
            try await client.setAudioBroadcast(ownerId: ownerId, audioId: audioId)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadInactiveFriends() async {
        guard let client else { return }
        do {
            inactiveFriends = try await client.getInactiveFriends()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadStickerPacks(force: Bool = false) async {
        guard let client else { return }
        if !force && !stickerPacks.isEmpty { return }
        isLoadingStickers = true
        defer { isLoadingStickers = false }
        do {
            stickerPacks = try await client.getStickerPacks()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    // MARK: - Links, Attachments, Snippets, Notes, Birthdays, Offline Audio

    func openScreenName(_ screenName: String, fallbackUrl: URL) async {
        guard let client else {
            NSWorkspace.shared.open(fallbackUrl)
            return
        }
        if let res = try? await client.resolveScreenName(screenName: screenName) {
            switch res {
            case .user(let id):
                openOwnerPage(id)
                return
            case .group(let id):
                openOwnerPage(-id)
                return
            case .unknown:
                break
            }
        }
        NSWorkspace.shared.open(fallbackUrl)
    }

    func openWallPost(ownerId: Int64, postId: Int64) async {
        if let existing = feedPosts.first(where: { $0.sourceId == ownerId && $0.postId == postId }) {
            openPost(existing)
            return
        }
        openOwnerPage(ownerId)
    }

    func getHistoryAttachments(peerId: Int64, mediaType: String) async -> [Attachment] {
        guard let client else { return [] }
        return (try? await client.getHistoryAttachments(peerId: peerId, mediaType: mediaType, count: 60)) ?? []
    }

    func createPostWithPhoto(ownerId: Int64, text: String, photoPath: String?, publishDate: Int64?) async {
        guard let client else { return }
        do {
            _ = try await client.createPostWithPhoto(ownerId: ownerId, message: text, photoPath: photoPath, publishDate: publishDate)
            await loadFeed(reset: true)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func replyComment(ownerId: Int64, postId: Int64, replyTo: Int64?, message: String) async {
        guard let client else { return }
        do {
            _ = try await client.replyComment(ownerId: ownerId, postId: postId, replyToComment: replyTo, message: message)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func likeComment(ownerId: Int64, commentId: Int64, add: Bool) async {
        guard let client else { return }
        do {
            try await client.likeComment(ownerId: ownerId, commentId: commentId, add: add)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func getAudioLyrics(ownerId: Int64, audioId: Int64) async -> String {
        guard let client else { return "" }
        return (try? await client.getAudioLyrics(ownerId: ownerId, audioId: audioId)) ?? ""
    }

    func loadBirthdays() async {
        guard let client else { return }
        if let list = try? await client.getFriendsBirthdays() {
            birthdays = list
        }
    }

    func downloadAlbum(ownerId: Int64, destFolder: URL) async -> Int {
        guard let client else { return 0 }
        guard let urls = try? await client.getAlbumPhotoUrls(ownerId: ownerId, count: 200) else { return 0 }
        var saved = 0
        for (idx, urlStr) in urls.enumerated() {
            guard let url = URL(string: urlStr) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                let dest = destFolder.appendingPathComponent("photo_\(idx + 1).jpg")
                if (try? data.write(to: dest)) != nil {
                    saved += 1
                }
            }
        }
        return saved
    }

    func createPlaylist(title: String) async {
        guard let client else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.createPlaylist(title: trimmed)
            await loadPlaylists()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func deleteMessagesBatch(peerId: Int64, messageIds: [Int64]) async {
        guard let client, !messageIds.isEmpty else { return }
        do {
            try await client.deleteMessagesBatch(peerId: peerId, messageIds: messageIds)
            let idSet = Set(messageIds)
            messagesByPeer[peerId]?.removeAll { idSet.contains($0.id) }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadSnippets() {
        guard let client else { return }
        snippets = (try? client.getSnippets()) ?? []
    }

    func saveSnippet(title: String, text: String) {
        guard let client else { return }
        _ = try? client.saveSnippet(title: title, text: text)
        loadSnippets()
    }

    func deleteSnippet(id: Int64) {
        guard let client else { return }
        try? client.deleteSnippet(id: id)
        loadSnippets()
    }

    func getContactNote(peerId: Int64) -> String {
        guard let client else { return "" }
        return (try? client.getContactNote(peerId: peerId)) ?? ""
    }

    func setContactNote(peerId: Int64, note: String) {
        guard let client else { return }
        try? client.setContactNote(peerId: peerId, note: note)
    }

    func toggleWatchOnline(userId: Int64) {
        guard let client else { return }
        _ = try? client.toggleWatchOnline(userId: userId)
        loadWatchedOnline()
    }

    func loadWatchedOnline() {
        guard let client else { return }
        watchedOnlineIds = (try? client.getWatchedOnline()) ?? []
    }

    func loadTopArtists() {
        guard let client else { return }
        topArtists = (try? client.getTopArtists(limit: 15)) ?? []
    }

    func scheduleMessageReminder(peerId: Int64, title: String, body: String, delaySeconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Напоминание: \(title)"
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(5, delaySeconds), repeats: false)
        let req = UNNotificationRequest(identifier: "vkmac-rem-\(peerId)-\(Int(Date().timeIntervalSince1970))", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private var offlineAudioDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("VKMac/offline_audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func offlineAudioKey(_ track: AudioTrack) -> String {
        "\(track.ownerId)_\(track.id)"
    }

    func offlineAudioURL(for track: AudioTrack) -> URL? {
        let file = offlineAudioDir.appendingPathComponent("\(offlineAudioKey(track)).mp3")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private var offlineTracksMetaUrl: URL {
        offlineAudioDir.appendingPathComponent("offline_tracks.json")
    }

    private struct OfflineTrackCodable: Codable {
        let id: Int64
        let ownerId: Int64
        let artist: String
        let title: String
        let durationSec: UInt32
        let streamUrl: String?
        let coverUrl: String?
    }

    func refreshOfflineAudioList() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: offlineAudioDir.path)) ?? []
        offlineAudioIds = Set(files.filter { $0.hasSuffix(".mp3") }.map { $0.replacingOccurrences(of: ".mp3", with: "") })
        if let data = try? Data(contentsOf: offlineTracksMetaUrl),
           let decoded = try? JSONDecoder().decode([OfflineTrackCodable].self, from: data) {
            offlineTracks = decoded
                .filter { offlineAudioIds.contains("\($0.ownerId)_\($0.id)") }
                .map { AudioTrack(id: $0.id, ownerId: $0.ownerId, artist: $0.artist, title: $0.title, durationSec: $0.durationSec, streamUrl: $0.streamUrl, coverUrl: $0.coverUrl) }
        } else {
            offlineTracks = []
        }
    }

    private func saveOfflineTracksMeta(_ list: [AudioTrack]) {
        let codable = list.map { OfflineTrackCodable(id: $0.id, ownerId: $0.ownerId, artist: $0.artist, title: $0.title, durationSec: $0.durationSec, streamUrl: $0.streamUrl, coverUrl: $0.coverUrl) }
        if let data = try? JSONEncoder().encode(codable) {
            try? data.write(to: offlineTracksMetaUrl)
        }
    }

    func downloadAudioOffline(_ track: AudioTrack) async {
        guard let urlStr = track.streamUrl, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let dest = offlineAudioDir.appendingPathComponent("\(offlineAudioKey(track)).mp3")
            try data.write(to: dest)
            var current = offlineTracks
            if !current.contains(where: { $0.id == track.id && $0.ownerId == track.ownerId }) {
                current.insert(track, at: 0)
            }
            saveOfflineTracksMeta(current)
            refreshOfflineAudioList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeOfflineAudio(_ track: AudioTrack) {
        let file = offlineAudioDir.appendingPathComponent("\(offlineAudioKey(track)).mp3")
        try? FileManager.default.removeItem(at: file)
        let updated = offlineTracks.filter { !($0.id == track.id && $0.ownerId == track.ownerId) }
        saveOfflineTracksMeta(updated)
        refreshOfflineAudioList()
    }

    // MARK: - Wave 3: Playlists, Ban, Friend Requests, Status, Media Comments, Watch Wall, Multi-Account

    func markAllAsRead() async {
        guard let client else { return }
        let unreadPeers = conversations.filter { $0.unreadCount > 0 }.map { $0.peerId }
        for pid in unreadPeers {
            try? await client.markAsRead(peerId: pid)
        }
        await loadConversations()
    }

    func addToPlaylist(ownerId: Int64, playlistId: Int64, track: AudioTrack) async {
        guard let client else { return }
        do {
            try await client.addToPlaylist(ownerId: ownerId, playlistId: playlistId, audioOwnerId: track.ownerId, audioId: track.id)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadBanned() async {
        guard let client else { return }
        if let list = try? await client.getBanned() {
            bannedUsers = list
        }
    }

    func banUser(_ ownerId: Int64) async {
        guard let client else { return }
        do {
            try await client.banUser(ownerId: ownerId)
            await loadBanned()
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func unbanUser(_ ownerId: Int64) async {
        guard let client else { return }
        do {
            try await client.unbanUser(ownerId: ownerId)
            bannedUsers.removeAll { $0.id == ownerId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func loadFriendRequests() async {
        guard let client else { return }
        if let list = try? await client.getFriendRequests() {
            friendRequests = list
        }
    }

    func acceptFriend(_ userId: Int64) async {
        guard let client else { return }
        do {
            try await client.acceptFriend(userId: userId)
            friendRequests.removeAll { $0.id == userId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func declineFriend(_ userId: Int64) async {
        guard let client else { return }
        do {
            try await client.declineFriend(userId: userId)
            friendRequests.removeAll { $0.id == userId }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func setStatus(_ text: String) async {
        guard let client else { return }
        do {
            try await client.setStatus(text: text)
            if let uid = currentUser?.id {
                await loadOwnerPage(ownerId: uid)
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func getMediaComments(isVideo: Bool, ownerId: Int64, itemId: Int64) async -> [CommentItem] {
        guard let client else { return [] }
        return (try? await client.getMediaComments(isVideo: isVideo, ownerId: ownerId, itemId: itemId)) ?? []
    }

    func createMediaComment(isVideo: Bool, ownerId: Int64, itemId: Int64, text: String) async {
        guard let client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.createMediaComment(isVideo: isVideo, ownerId: ownerId, itemId: itemId, message: trimmed)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func toggleWatchWall(_ ownerId: Int64) {
        guard let client else { return }
        _ = try? client.toggleWatchWall(ownerId: ownerId)
        loadWatchedWalls()
    }

    func loadWatchedWalls() {
        guard let client else { return }
        watchedWalls = (try? client.getWatchedWalls()) ?? []
    }

    func loadSavedAccounts() {
        guard let client else { return }
        savedAccounts = (try? client.getSavedAccounts()) ?? []
    }

    func switchAccount(_ userId: Int64) async {
        guard let client else { return }
        do {
            let state = try await client.switchAccount(userId: userId)
            authState = state
            if case .authenticated = state {
                conversations = []
                messagesByPeer = [:]
                feedPosts = []
                tracks = []
                ownerPageCache = [:]
                await loadInitialData()
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func addAnotherAccount() {
        authState = .loggedOut
    }

    func removeSavedAccount(_ userId: Int64) {
        guard let client else { return }
        try? client.removeSavedAccount(userId: userId)
        loadSavedAccounts()
    }

    // MARK: - Wave 4: Archive, Stats, Ignore Post, Fave Pages, Repost to Chat, Similar Audio

    func loadArchivedPeers() {
        guard let client else { return }
        archivedPeerIds = (try? client.getArchivedPeers()) ?? []
    }

    func toggleArchive(peerId: Int64) {
        guard let client else { return }
        _ = try? client.toggleArchiveConversation(peerId: peerId)
        loadArchivedPeers()
    }

    func getChatStats(peerId: Int64) -> ChatStats? {
        guard let client else { return nil }
        return try? client.getChatStats(peerId: peerId)
    }

    func ignorePost(_ post: FeedPost) async {
        guard let client else { return }
        feedPosts.removeAll { $0.postId == post.postId && $0.sourceId == post.sourceId }
        try? await client.ignoreNewsfeedItem(ownerId: post.sourceId, postId: post.postId)
    }

    func loadFavePages() async {
        guard let client else { return }
        if let list = try? await client.getFavePages() {
            favePages = list
        }
    }

    func sendWallToPeer(peerId: Int64, ownerId: Int64, postId: Int64) async {
        guard let client else { return }
        do {
            _ = try await client.sendWallToPeer(peerId: peerId, ownerId: ownerId, postId: postId)
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    func playSimilarTracks(_ track: AudioTrack) async {
        guard let client else { return }
        do {
            let list = try await client.getSimilarAudio(ownerId: track.ownerId, audioId: track.id, count: 40)
            if !list.isEmpty {
                AudioPlayerService.shared.play(track: list[0], in: list)
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }

    @Published var dismissedKeyboardMessageIds: Set<Int64> = []
    @Published var conversationKeyboards: [Int64: BotKeyboard] = [:]

    func sendBotButton(peerId: Int64, messageId: Int64?, oneTime: Bool, button: BotKeyboardButton) async {
        if button.actionType == "open_link", let link = button.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let client else { return }
        if oneTime {
            conversationKeyboards[peerId] = nil
            if let messageId {
                dismissedKeyboardMessageIds.insert(messageId)
            }
        }
        do {
            let msg = try await client.sendMessageWithPayload(
                peerId: peerId,
                text: button.label,
                payload: button.payload
            )
            var current = messagesByPeer[peerId] ?? []
            if !current.contains(where: { $0.id == msg.id }) {
                current.append(msg)
                current.sort { $0.date < $1.date }
                messagesByPeer[peerId] = current
            }
        } catch {
            errorMessage = formatVkError(error)
        }
    }
}
