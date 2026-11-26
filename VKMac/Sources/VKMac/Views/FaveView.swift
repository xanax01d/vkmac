import SwiftUI

private enum FaveCategory: String, CaseIterable {
    case all = "Все"
    case posts = "Посты"
    case links = "Ссылки"
    case pages = "Страницы"
}

struct FaveView: View {
    @EnvironmentObject private var appState: AppState
    @State private var category: FaveCategory = .all

    private var filteredItems: [FaveItem] {
        switch category {
        case .all: return appState.faveItems
        case .posts: return appState.faveItems.filter { $0.post != nil }
        case .links: return appState.faveItems.filter { $0.linkUrl != nil }
        case .pages: return []
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Picker("", selection: $category) {
                    ForEach(FaveCategory.allCases, id: \.self) { c in
                        Text(c.rawValue).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                if category == .pages {
                    if appState.favePages.isEmpty {
                        Text("Избранных страниц пока нет")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(appState.favePages, id: \.id) { page in
                            Button {
                                appState.openOwnerPage(page.id)
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(urlString: page.avatarUrl, title: page.name, size: 36)
                                    Text(page.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if filteredItems.isEmpty {
                    Text("Закладок пока нет")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(filteredItems.enumerated()), id: \.offset) { _, item in
                        if let post = item.post {
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
                                    Task {
                                        await appState.removeBookmark(ownerId: post.sourceId, postId: post.postId)
                                    }
                                }
                            )
                        } else if let urlStr = item.linkUrl, let url = URL(string: urlStr) {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "link")
                                    Text(item.linkTitle ?? urlStr)
                                    Spacer()
                                }
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Закладки")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await appState.loadFave() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить закладки")
            }
        }
        .onChange(of: category) { newCat in
            if newCat == .pages && appState.favePages.isEmpty {
                Task { await appState.loadFavePages() }
            }
        }
        .task {
            if appState.faveItems.isEmpty {
                await appState.loadFave()
            }
        }
    }
}
