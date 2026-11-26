import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    let onClose: () -> Void

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Быстрый переход: раздел, чат, друг, группа, трек...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Button("Esc") {
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            List {
                if !matchingTabs.isEmpty {
                    Section("Разделы") {
                        ForEach(matchingTabs) { tab in
                            Button {
                                appState.selectedTab = tab
                                onClose()
                            } label: {
                                Label(tab.rawValue, systemImage: tab.systemImage)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !matchingConversations.isEmpty {
                    Section("Диалоги") {
                        ForEach(matchingConversations.prefix(8), id: \.peerId) { conv in
                            Button {
                                appState.selectedTab = .chats
                                appState.selectedPeerId = conv.peerId
                                onClose()
                            } label: {
                                HStack(spacing: 8) {
                                    AvatarView(urlString: conv.avatarUrl, title: conv.title, size: 24)
                                    Text(conv.title)
                                    Spacer()
                                    if conv.unreadCount > 0 {
                                        Text("\(conv.unreadCount)")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(appState.accentColor)
                                            .foregroundStyle(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !matchingOwners.isEmpty {
                    Section("Люди и группы") {
                        ForEach(matchingOwners.prefix(8), id: \.id) { owner in
                            Button {
                                onClose()
                                appState.openOwnerPage(owner.id)
                            } label: {
                                HStack(spacing: 8) {
                                    AvatarView(urlString: owner.avatarUrl, title: owner.name, size: 24)
                                    Text(owner.name)
                                    Spacer()
                                    Text(owner.isGroup ? "Группа" : "Друг")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !matchingTracks.isEmpty {
                    Section("Музыка") {
                        ForEach(matchingTracks.prefix(6), id: \.id) { track in
                            Button {
                                audioPlayer.play(track: track, in: appState.tracks)
                                onClose()
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(appState.accentColor)
                                    Text("\(track.artist) — \(track.title)")
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 440)
    }

    private var q: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var matchingTabs: [SidebarTab] {
        guard !q.isEmpty else { return SidebarTab.allCases }
        return SidebarTab.allCases.filter { $0.rawValue.lowercased().contains(q) }
    }

    private var matchingConversations: [ConversationItem] {
        guard !q.isEmpty else { return Array(appState.conversations.prefix(5)) }
        return appState.conversations.filter { $0.title.lowercased().contains(q) }
    }

    private var matchingOwners: [OwnerSummary] {
        let combined = appState.friends + appState.groups
        guard !q.isEmpty else { return [] }
        return combined.filter { $0.name.lowercased().contains(q) }
    }

    private var matchingTracks: [AudioTrack] {
        guard !q.isEmpty else { return [] }
        return appState.tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }
}
