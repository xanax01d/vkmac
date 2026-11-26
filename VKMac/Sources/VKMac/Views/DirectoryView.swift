import SwiftUI

enum DirectoryMode {
    case friends
    case groups
}

private enum FriendsSegment: String, CaseIterable {
    case friends = "Друзья"
    case followers = "Подписчики"
    case requests = "Заявки"
    case birthdays = "Дни рождения"
}

struct DirectoryView: View {
    @EnvironmentObject private var appState: AppState
    let mode: DirectoryMode

    @State private var friendsSegment: FriendsSegment = .friends
    @State private var searchText: String = ""
    @State private var selectedOwnerId: Int64?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if mode == .friends {
                        Picker("", selection: $friendsSegment) {
                            ForEach(FriendsSegment.allCases, id: \.self) { seg in
                                Text(seg.rawValue).tag(seg)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    TextField("Поиск...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(10)

                Divider()

                if mode == .friends && friendsSegment == .requests {
                    List(appState.friendRequests, id: \.id) { req in
                        HStack(spacing: 10) {
                            AvatarView(urlString: req.avatarUrl, title: req.name, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(req.name).font(.subheadline.weight(.semibold))
                                if let msg = req.message, !msg.isEmpty {
                                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Принять") {
                                Task { await appState.acceptFriend(req.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Отклонить") {
                                Task { await appState.declineFriend(req.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .listStyle(.inset)
                    .task {
                        await appState.loadFriendRequests()
                    }
                } else if mode == .friends && friendsSegment == .birthdays {
                    List(appState.birthdays, id: \.id) { b in
                        HStack(spacing: 10) {
                            AvatarView(urlString: b.avatarUrl, title: b.name, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name).font(.subheadline.weight(.semibold))
                                Text(b.bdate).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Поздравить") {
                                appState.selectedPeerId = b.id
                                appState.selectedTab = .chats
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .listStyle(.inset)
                    .task {
                        if appState.birthdays.isEmpty {
                            await appState.loadBirthdays()
                        }
                    }
                } else {
                List(filteredItems, id: \.id, selection: $selectedOwnerId) { item in
                    HStack(spacing: 10) {
                        AvatarView(urlString: item.avatarUrl, title: item.name, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if item.isVerified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(appState.accentColor)
                                }
                                if !item.isGroup && item.online {
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
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                }
                .listStyle(.inset)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            if let selectedOwnerId {
                OwnerPageView(ownerId: selectedOwnerId)
                    .frame(minWidth: 440)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: mode == .friends ? "person.2" : "rectangle.stack.person.crop")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(mode == .friends ? "Выберите пользователя" : "Выберите группу")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(mode == .friends ? "Друзья" : "Группы")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await reloadCurrent() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить список")
            }
        }
        .task(id: "\(mode)_\(friendsSegment.rawValue)") {
            selectedOwnerId = nil
            await loadIfNeeded()
        }
    }

    private func reloadCurrent() async {
        switch mode {
        case .friends:
            if friendsSegment == .friends {
                await appState.loadFriends()
            } else {
                await appState.loadMyFollowers()
            }
        case .groups:
            await appState.loadGroups()
        }
    }

    private func loadIfNeeded() async {
        switch mode {
        case .friends:
            if friendsSegment == .friends && appState.friends.isEmpty {
                await appState.loadFriends()
            } else if friendsSegment == .followers && appState.followers.isEmpty {
                await appState.loadMyFollowers()
            }
        case .groups:
            if appState.groups.isEmpty {
                await appState.loadGroups()
            }
        }
    }

    private var filteredItems: [OwnerSummary] {
        let source: [OwnerSummary]
        switch mode {
        case .friends:
            source = friendsSegment == .friends ? appState.friends : appState.followers
        case .groups:
            source = appState.groups
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return source }
        return source.filter {
            $0.name.lowercased().contains(query) ||
            ($0.screenName?.lowercased().contains(query) ?? false) ||
            ($0.subtitle?.lowercased().contains(query) ?? false)
        }
    }
}
