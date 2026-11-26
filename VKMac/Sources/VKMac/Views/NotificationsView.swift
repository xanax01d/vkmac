import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(appState.notifications.enumerated()), id: \.offset) { _, item in
                    notificationCard(item)
                }
            }
            .padding(14)
        }
        .navigationTitle("Уведомления")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await appState.loadNotifications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить уведомления")
            }
        }
        .task {
            if appState.notifications.isEmpty {
                await appState.loadNotifications()
            }
        }
    }

    @ViewBuilder
    private func notificationCard(_ item: NotificationItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if item.actorId != 0 {
                    appState.openOwnerPage(item.actorId)
                }
            } label: {
                AvatarView(urlString: item.actorAvatar, title: item.actorName, size: 42)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.actorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let actionLabel = kindLabel(item.kind) {
                        Text(actionLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(formatDate(item.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func kindLabel(_ kind: String) -> String? {
        switch kind {
        case "like_post": return "оценил(а) запись"
        case "like_comment": return "оценил(а) комментарий"
        case "like_photo": return "оценил(а) фото"
        case "comment_post": return "прокомментировал(а) запись"
        case "reply_comment": return "ответил(а) на комментарий"
        case "copy_post": return "поделился(лась) записью"
        case "follow": return "подписался(лась) на вас"
        case "friend_accepted": return "принял(а) заявку в друзья"
        case "mention": return "упомянул(а) вас"
        case "like": return "оценил(а)"
        case "comment": return "прокомментировал(а)"
        case "repost": return "поделился(лась)"
        case "custom", "image", "friend_found", "":
            return nil
        default:
            return nil
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
