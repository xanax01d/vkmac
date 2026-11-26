import AppKit
import SwiftUI

@MainActor
final class PopoutChatWindow {
    static let shared = PopoutChatWindow()

    private var windows: [Int64: NSWindow] = [:]

    func open(peerId: Int64, title: String, appState: AppState) {
        if let existing = windows[peerId] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let content = PopoutChatContentView(peerId: peerId, title: title)
            .environmentObject(appState)
            .frame(minWidth: 460, minHeight: 540)

        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(NSSize(width: 520, height: 640))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        windows[peerId] = window
    }

    func setFloating(peerId: Int64, floating: Bool) {
        windows[peerId]?.level = floating ? .floating : .normal
    }
}

private struct PopoutChatContentView: View {
    @EnvironmentObject private var appState: AppState
    let peerId: Int64
    let title: String
    @State private var draft: String = ""
    @State private var isFloating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    isFloating.toggle()
                    PopoutChatWindow.shared.setFloating(peerId: peerId, floating: isFloating)
                } label: {
                    Image(systemName: isFloating ? "pin.fill" : "pin")
                        .foregroundStyle(isFloating ? appState.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Поверх всех окон")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        let msgs = appState.messagesByPeer[peerId] ?? []
                        ForEach(msgs, id: \.id) { msg in
                            HStack {
                                if msg.isOut { Spacer(minLength: 50) }
                                VStack(alignment: .leading, spacing: 4) {
                                    if !msg.text.isEmpty {
                                        Text(msg.text)
                                            .textSelection(.enabled)
                                    }
                                    if !msg.attachments.isEmpty && msg.text.isEmpty {
                                        Text("[Вложение]")
                                            .font(.caption)
                                            .opacity(0.8)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(msg.isOut ? appState.accentColor : Color.secondary.opacity(0.15))
                                .foregroundStyle(msg.isOut ? Color.white : Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                if !msg.isOut { Spacer(minLength: 50) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.messagesByPeer[peerId]?.last?.id) { lastId in
                    if let lastId {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Сообщение...", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .task {
            await appState.loadMessages(peerId: peerId)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await appState.sendMessage(peerId: peerId, text: text) }
    }
}
