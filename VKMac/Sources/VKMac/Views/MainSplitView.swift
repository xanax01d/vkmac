import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var photoViewer = PhotoViewerWindow.shared
    @State private var isFullScreen: Bool = false

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
            if let error = appState.errorMessage, !error.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Закрыть") {
                        appState.errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.18))
                Divider()
            }

            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let user = appState.currentUser {
                            Button {
                                appState.presentedPost = nil
                                appState.selectedTab = .myPage
                            } label: {
                                HStack(spacing: 8) {
                                    AvatarView(
                                        urlString: user.avatarUrl,
                                        title: "\(user.firstName) \(user.lastName)",
                                        size: 28
                                    )
                                    Text("\(user.firstName) \(user.lastName)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, isFullScreen ? 10 : 42)
                    .padding(.bottom, 8)

                    Divider()

                    List(
                        visibleTabs,
                        selection: Binding<SidebarTab?>(
                            get: { appState.selectedTab },
                            set: {
                                if let value = $0 {
                                    appState.presentedPost = nil
                                    appState.selectedTab = value
                                }
                            }
                        )
                    ) { tab in
                        HStack {
                            Label(tab.rawValue, systemImage: tab.systemImage)
                            Spacer()
                            if tab == .chats && appState.totalUnreadCount > 0 {
                                Text("\(appState.totalUnreadCount)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(appState.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(tab)
                    }
                    .listStyle(.sidebar)
                }
                .ignoresSafeArea(.container, edges: .top)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
            } detail: {
                if let post = appState.presentedPost {
                    PostDetailView(post: post) {
                        appState.presentedPost = nil
                    }
                    .id("\(post.sourceId)_\(post.postId)")
                } else {
                switch appState.selectedTab {
                case .myPage:
                    if let userId = appState.currentUser?.id {
                        OwnerPageView(ownerId: userId)
                            .navigationTitle("Моя страница")
                    } else {
                        ProgressView("Загрузка профиля...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task {
                                await appState.refreshCurrentUser()
                            }
                    }
                case .chats:
                    ChatsView()
                case .feed:
                    FeedView()
                case .fave:
                    FaveView()
                case .notifications:
                    NotificationsView()
                case .friends:
                    DirectoryView(mode: .friends)
                case .groups:
                    DirectoryView(mode: .groups)
                case .videos:
                    VideosView()
                case .music:
                    MusicView()
                case .search:
                    SearchView()
                case .settings:
                    SettingsView()
                case .help:
                    HelpView()
                }
                }
            }

            MiniPlayerBar()
        }
        if let presentation = photoViewer.activePresentation {
            PhotoViewerView(
                items: presentation.items,
                initialIndex: presentation.initialIndex,
                onClose: {
                    PhotoViewerWindow.shared.close()
                }
            )
            .id(presentation.id)
            .transition(.opacity)
            .zIndex(100)
        }
        }
        .sheet(item: Binding<IdentifiableOwnerId?>(
            get: { appState.presentedOwnerId.map(IdentifiableOwnerId.init(id:)) },
            set: { appState.presentedOwnerId = $0?.id }
        )) { item in
            OwnerPageView(ownerId: item.id) {
                appState.presentedOwnerId = nil
            }
            .environmentObject(appState)
            .frame(width: 680, height: 640)
        }
        .sheet(isPresented: $appState.showCommandPalette) {
            CommandPaletteView {
                appState.showCommandPalette = false
            }
            .environmentObject(appState)
            .tint(appState.accentColor)
        }
        .tint(appState.accentColor)
        .onAppear {
            isFullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) == true
            TouchBarController.shared.attach(appState: appState, audioPlayer: AudioPlayerService.shared)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onChange(of: appState.selectedTab) { _ in TouchBarController.shared.refresh() }
        .onChange(of: appState.presentedPost?.postId) { _ in TouchBarController.shared.refresh() }
        .onChange(of: appState.totalUnreadCount) { _ in TouchBarController.shared.refresh() }
        .onChange(of: appState.stealthMode) { _ in TouchBarController.shared.refresh() }
    }

    private var visibleTabs: [SidebarTab] {
        switch appState.appMode {
        case "messenger":
            return [.chats, .friends, .notifications, .search, .settings, .help]
        case "music":
            return [.music, .search, .settings, .help]
        default:
            return SidebarTab.allCases
        }
    }
}

private struct IdentifiableOwnerId: Identifiable {
    let id: Int64
}

private struct IdentifiablePost: Identifiable {
    let post: FeedPost
    var id: String { "\(post.sourceId)_\(post.postId)" }
}
