import SwiftUI

struct PostDetailView: View {
    @EnvironmentObject private var appState: AppState
    let post: FeedPost
    let onClose: () -> Void

    @State private var commentText: String = ""
    @State private var isSending: Bool = false
    @State private var replyToCommentId: Int64? = nil

    private var postKey: String {
        "\(post.sourceId)_\(post.postId)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    onClose()
                } label: {
                    Label("Назад", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Text("Запись")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FeedPostCard(
                        post: currentPost,
                        onLike: {
                            Task { await appState.toggleLike(post: currentPost) }
                        },
                        onAuthorTap: {
                            onClose()
                            appState.openOwnerPage(currentPost.sourceId)
                        },
                        onCommentTap: {},
                        onRepostTap: {
                            Task { await appState.repostPost(post: currentPost) }
                        }
                    )

                    Text("Комментарии")
                        .font(.headline)

                    let comments = appState.commentsByPost[postKey] ?? []
                    if comments.isEmpty {
                        Text("Комментариев пока нет")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(comments, id: \.id) { comment in
                                HStack(alignment: .top, spacing: 10) {
                                    Button {
                                        onClose()
                                        appState.openOwnerPage(comment.fromId)
                                    } label: {
                                        AvatarView(urlString: comment.authorAvatar, title: comment.authorName, size: 30)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(comment.authorName)
                                                .font(.subheadline.weight(.semibold))
                                            Text(formatDate(comment.date))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if !comment.text.isEmpty {
                                            Text(comment.text)
                                                .font(.callout)
                                                .textSelection(.enabled)
                                        }
                                        HStack(spacing: 12) {
                                            Button("Ответить") {
                                                commentText = "\(comment.authorName), "
                                                replyToCommentId = comment.id
                                            }
                                            .font(.caption)
                                            .buttonStyle(.borderless)

                                            Button {
                                                Task {
                                                    await appState.likeComment(ownerId: post.sourceId, commentId: comment.id, add: true)
                                                }
                                            } label: {
                                                Label("Нравится", systemImage: "heart")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Написать комментарий...", text: $commentText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitComment()
                    }

                Button {
                    submitComment()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appState.loadComments(ownerId: post.sourceId, postId: post.postId)
        }
    }

    private var currentPost: FeedPost {
        appState.feedPosts.first(where: { $0.postId == post.postId && $0.sourceId == post.sourceId }) ?? post
    }

    private func submitComment() {
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let replyTo = replyToCommentId
        commentText = ""
        replyToCommentId = nil
        isSending = true
        Task {
            if let replyTo {
                await appState.replyComment(ownerId: post.sourceId, postId: post.postId, replyTo: replyTo, message: trimmed)
                await appState.loadComments(ownerId: post.sourceId, postId: post.postId)
            } else {
                await appState.createComment(ownerId: post.sourceId, postId: post.postId, text: trimmed)
            }
            isSending = false
        }
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
