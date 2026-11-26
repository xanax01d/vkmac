import SwiftUI

private enum SearchTab: String, CaseIterable {
    case users = "Люди"
    case groups = "Группы"
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String = ""
    @State private var tab: SearchTab = .users

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Поиск пользователей и сообществ...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await appState.performGlobalSearch(query: query) }
                    }

                Button("Искать") {
                    Task { await appState.performGlobalSearch(query: query) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)

            Picker("", selection: $tab) {
                ForEach(SearchTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            let items = tab == .users ? appState.searchUsersResult : appState.searchGroupsResult
            List(items, id: \.id) { item in
                Button {
                    appState.openOwnerPage(item.id)
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(urlString: item.avatarUrl, title: item.name, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                if item.isVerified {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(appState.accentColor)
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
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .navigationTitle("Поиск")
    }
}
