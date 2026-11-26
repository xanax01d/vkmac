import AppKit
import AVFoundation
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

enum ChatFolder: String, CaseIterable, Identifiable {
    case all = "Все"
    case unread = "Непроч."
    case direct = "Личные"
    case group = "Беседы"
    case communities = "Группы"
    case archive = "Архив"
    var id: String { rawValue }
}

extension MessageItem: Identifiable {}

struct ChatsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var draftText: String = ""
    @State private var searchQuery: String = ""
    @State private var selectedFolder: ChatFolder = .all
    @State private var replyToMessage: MessageItem?
    @State private var editingMessage: MessageItem?
    @State private var attachedPhotoPath: String?
    @State private var attachedDocPath: String?

    @State private var showChatSearch: Bool = false
    @State private var chatSearchQuery: String = ""
    @State private var chatSearchResults: [MessageItem] = []

    @State private var showChatInfoSheet: Bool = false
    @State private var chatMembers: [ChatMember] = []
    @State private var renameChatTitle: String = ""

    @State private var forwardingMessage: MessageItem?
    @State private var showStickerPicker: Bool = false
    @State private var currentPresence: UserPresence?
    @StateObject private var voiceRecorder = VoiceRecorderHelper()

    @State private var showAttachmentsSheet: Bool = false
    @State private var showNotePopover: Bool = false
    @State private var contactNoteDraft: String = ""
    @State private var showSnippetsPopover: Bool = false
    @State private var isSelectionMode: Bool = false
    @State private var selectedMessageIds: Set<Int64> = []
    @State private var showBatchForwardSheet: Bool = false
    @State private var showJumpDatePopover: Bool = false
    @State private var jumpDate: Date = Date()
    @State private var scrollTargetId: Int64? = nil
    @State private var showStatsPopover: Bool = false
    @State private var chatStats: ChatStats? = nil
    @State private var keyMonitor: Any? = nil

    var body: some View {
        HSplitView {
            conversationsList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 370)

            chatDetail
                .frame(minWidth: 440)
        }
        .navigationTitle("Чаты")
        .task {
            if appState.conversations.isEmpty {
                await appState.loadConversations()
            }
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.modifierFlags.contains(.command),
                       event.charactersIgnoringModifiers?.lowercased() == "v",
                       NSImage(pasteboard: NSPasteboard.general) != nil {
                        pasteImageFromClipboard()
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .sheet(item: $forwardingMessage) { msg in
            ForwardMessageSheet(message: msg) { targetPeerId in
                Task {
                    await appState.forwardMessages(peerId: targetPeerId, messageIds: [msg.id])
                }
                forwardingMessage = nil
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showBatchForwardSheet) {
            if appState.selectedPeerId != nil {
                ForwardMultipleSheet(count: selectedMessageIds.count) { targetPeerId in
                    let ids = Array(selectedMessageIds).sorted()
                    selectedMessageIds.removeAll()
                    isSelectionMode = false
                    showBatchForwardSheet = false
                    Task { await appState.forwardMessages(peerId: targetPeerId, messageIds: ids) }
                }
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showAttachmentsSheet) {
            if let peerId = appState.selectedPeerId {
                ChatAttachmentsSheet(peerId: peerId)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showChatInfoSheet) {
            if let peerId = appState.selectedPeerId {
                ChatInfoSheet(
                    peerId: peerId,
                    members: chatMembers,
                    title: $renameChatTitle,
                    onSaveTitle: {
                        Task { await appState.setChatTitle(peerId: peerId, title: renameChatTitle) }
                    }
                )
            }
        }
    }

    private var filteredConversations: [ConversationItem] {
        let archivedSet = Set(appState.archivedPeerIds)
        let base = appState.conversations.filter { conv in
            let isArch = archivedSet.contains(conv.peerId)
            switch selectedFolder {
            case .all: return !isArch
            case .unread: return !isArch && conv.unreadCount > 0
            case .direct: return !isArch && conv.peerId > 0 && conv.peerId < 2_000_000_000
            case .group: return !isArch && conv.peerId >= 2_000_000_000
            case .communities: return !isArch && conv.peerId < 0
            case .archive: return isArch
            }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched = q.isEmpty ? base : base.filter {
            $0.title.lowercased().contains(q) || $0.lastMessageText.lowercased().contains(q)
        }
        let pinnedSet = Set(appState.pinnedPeerIds)
        return searched.sorted { a, b in
            let pa = pinnedSet.contains(a.peerId)
            let pb = pinnedSet.contains(b.peerId)
            if pa != pb { return pa }
            return a.lastMessageDate > b.lastMessageDate
        }
    }

    private var conversationsList: some View {
        VStack(spacing: 0) {
            TextField("Поиск по диалогам...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ChatFolder.allCases) { folder in
                        Button(folder.rawValue) {
                            selectedFolder = folder
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedFolder == folder ? appState.accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            Divider()
            List(filteredConversations, id: \.peerId, selection: $appState.selectedPeerId) { conv in
                ConversationRow(
                    conversation: conv,
                    isPinned: appState.pinnedPeerIds.contains(conv.peerId)
                )
                .tag(conv.peerId)
                .contextMenu {
                    Button(appState.pinnedPeerIds.contains(conv.peerId) ? "Открепить" : "Закрепить") {
                        appState.togglePin(peerId: conv.peerId)
                    }
                    Button(appState.archivedPeerIds.contains(conv.peerId) ? "Вернуть из архива" : "В архив") {
                        appState.toggleArchive(peerId: conv.peerId)
                    }
                    Button("Открыть в отдельном окне") {
                        PopoutChatWindow.shared.open(peerId: conv.peerId, title: conv.title, appState: appState)
                    }
                }
            }
            .listStyle(.inset)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await appState.markAllAsRead() }
                } label: {
                    Image(systemName: "envelope.open")
                }
                .help("Отметить все чаты прочитанными")

                Button {
                    Task { await appState.loadConversations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить диалоги")
            }
        }
        .onChange(of: appState.selectedPeerId) { newPeerId in
            replyToMessage = nil
            editingMessage = nil
            attachedPhotoPath = nil
            attachedDocPath = nil
            showChatSearch = false
            chatSearchResults = []
            currentPresence = nil
            if let peerId = newPeerId {
                draftText = appState.loadDraft(peerId: peerId)
                Task {
                    await appState.loadMessages(peerId: peerId)
                    await appState.markAsRead(peerId: peerId)
                    if peerId > 0 && peerId < 2_000_000_000 {
                        currentPresence = await appState.getUserPresence(userId: peerId)
                    }
                }
            }
        }
        .onChange(of: draftText) { newText in
            if let peerId = appState.selectedPeerId, editingMessage == nil {
                appState.saveDraft(peerId: peerId, text: newText)
            }
        }
    }

    @ViewBuilder
    private var chatDetail: some View {
        if let peerId = appState.selectedPeerId,
           let conversation = appState.conversations.first(where: { $0.peerId == peerId }) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        if peerId < 2_000_000_000 && peerId != 0 {
                            appState.openOwnerPage(peerId)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(urlString: conversation.avatarUrl, title: conversation.title, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(conversation.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                if appState.typingByPeer[peerId] != nil {
                                    Text("печатает...")
                                        .font(.caption)
                                        .foregroundStyle(appState.accentColor)
                                } else if let p = currentPresence {
                                    Text(p.online ? "онлайн" : formatLastSeen(p.lastSeen ?? 0))
                                        .font(.caption)
                                        .foregroundStyle(p.online ? Color.green : Color.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()

                    Button {
                        showChatSearch.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Поиск по чату")

                    Button {
                        showJumpDatePopover.toggle()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .buttonStyle(.borderless)
                    .help("Перейти к дате")
                    .popover(isPresented: $showJumpDatePopover) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Перейти к дате")
                                .font(.headline)
                            DatePicker("", selection: $jumpDate, displayedComponents: [.date])
                                .datePickerStyle(.graphical)
                            HStack {
                                Spacer()
                                Button("Найти") {
                                    let dayStart = Int64(Calendar.current.startOfDay(for: jumpDate).timeIntervalSince1970)
                                    let msgs = appState.messagesByPeer[peerId] ?? []
                                    if let target = msgs.first(where: { $0.date >= dayStart }) ?? msgs.first {
                                        scrollTargetId = target.id
                                    }
                                    showJumpDatePopover = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(12)
                    }

                    Button {
                        showAttachmentsSheet = true
                    } label: {
                        Image(systemName: "paperclip.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Вложения диалога (Фото, Видео, Файлы, Ссылки)")

                    Button {
                        contactNoteDraft = appState.getContactNote(peerId: peerId)
                        showNotePopover.toggle()
                    } label: {
                        Image(systemName: "note.text")
                    }
                    .buttonStyle(.borderless)
                    .help("Локальная заметка о контакте")
                    .popover(isPresented: $showNotePopover) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Заметка о контакте")
                                .font(.headline)
                            TextEditor(text: $contactNoteDraft)
                                .frame(width: 240, height: 110)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                            HStack {
                                Spacer()
                                Button("Сохранить") {
                                    appState.setContactNote(peerId: peerId, note: contactNoteDraft)
                                    showNotePopover = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(12)
                    }

                    Group {
                        Button {
                            isSelectionMode.toggle()
                            if !isSelectionMode { selectedMessageIds.removeAll() }
                        } label: {
                            Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                                .foregroundStyle(isSelectionMode ? appState.accentColor : .primary)
                        }
                        .buttonStyle(.borderless)
                        .help("Выбрать несколько сообщений")

                        if peerId >= 2_000_000_000 {
                            Button {
                                renameChatTitle = conversation.title
                                showChatInfoSheet = true
                                Task { chatMembers = await appState.getChatMembers(peerId: peerId) }
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Информация о беседе")
                        }

                        Menu {
                            Button("Экспортировать в .txt") {
                                exportCurrentChat(peerId: peerId, title: conversation.title)
                            }
                            Button("Экспортировать в .html (с медиа)") {
                                exportCurrentChatHTML(peerId: peerId, title: conversation.title)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Экспорт истории")

                        Button {
                            chatStats = appState.getChatStats(peerId: peerId)
                            showStatsPopover.toggle()
                        } label: {
                            Image(systemName: "chart.bar")
                        }
                        .buttonStyle(.borderless)
                        .help("Статистика переписки")
                        .popover(isPresented: $showStatsPopover) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Статистика (из кэша)").font(.headline)
                                if let st = chatStats {
                                    Text("Всего сообщений: \(st.totalMessages)").font(.caption)
                                    Text("Исходящих: \(st.outgoingCount)").font(.caption)
                                    Text("Входящих: \(st.incomingCount)").font(.caption)
                                    Text("Пик активности: \(st.topHour):00").font(.caption)
                                } else {
                                    Text("Нет данных").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                        }

                        Button {
                            PopoutChatWindow.shared.open(peerId: peerId, title: conversation.title, appState: appState)
                        } label: {
                            Image(systemName: "uiwindow.split.2x1")
                        }
                        .buttonStyle(.borderless)
                        .help("Открыть в отдельном окне")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                if showChatSearch {
                    HStack(spacing: 8) {
                        TextField("Поиск сообщений...", text: $chatSearchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task {
                                    chatSearchResults = await appState.searchMessages(peerId: peerId, query: chatSearchQuery)
                                }
                            }
                        Button("Найти") {
                            Task {
                                chatSearchResults = await appState.searchMessages(peerId: peerId, query: chatSearchQuery)
                            }
                        }
                        .buttonStyle(.bordered)
                        Button("Закрыть") {
                            showChatSearch = false
                            chatSearchResults = []
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.06))
                }

                if let pinnedMsg = appState.pinnedMessageByPeer[peerId] {
                    Button {
                        scrollTargetId = pinnedMsg.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(appState.accentColor)
                            Text(pinnedMsg.text.isEmpty ? "Закреплённое сообщение" : pinnedMsg.text)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(appState.accentColor.opacity(0.10))
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            let msgs = showChatSearch && !chatSearchResults.isEmpty
                                ? chatSearchResults
                                : (appState.messagesByPeer[peerId] ?? [])
                            ForEach(msgs, id: \.id) { msg in
                                HStack(spacing: 8) {
                                    if isSelectionMode {
                                        Button {
                                            if selectedMessageIds.contains(msg.id) {
                                                selectedMessageIds.remove(msg.id)
                                            } else {
                                                selectedMessageIds.insert(msg.id)
                                            }
                                        } label: {
                                            Image(systemName: selectedMessageIds.contains(msg.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedMessageIds.contains(msg.id) ? appState.accentColor : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    MessageBubble(message: msg) { targetId in
                                        scrollTargetId = targetId
                                    }
                                }
                                .id(msg.id)
                                .contextMenu {
                                        Button("Ответить") {
                                            editingMessage = nil
                                            replyToMessage = msg
                                        }
                                        Button("Переслать") {
                                            forwardingMessage = msg
                                        }
                                        Button("Напомнить через 1 час") {
                                            appState.scheduleMessageReminder(
                                                peerId: peerId,
                                                title: conversation.title,
                                                body: msg.text.isEmpty ? "Сообщение" : msg.text,
                                                delaySeconds: 3600
                                            )
                                        }
                                        if peerId >= 2_000_000_000 {
                                            Button("Закрепить сообщение") {
                                                Task { await appState.pinMessage(peerId: peerId, messageId: msg.id) }
                                            }
                                        }
                                        Menu("Реакция") {
                                            Button("❤️") { Task { await appState.sendReaction(peerId: peerId, messageId: msg.id, reactionId: 1) } }
                                            Button("🔥") { Task { await appState.sendReaction(peerId: peerId, messageId: msg.id, reactionId: 2) } }
                                            Button("😂") { Task { await appState.sendReaction(peerId: peerId, messageId: msg.id, reactionId: 3) } }
                                            Button("👍") { Task { await appState.sendReaction(peerId: peerId, messageId: msg.id, reactionId: 5) } }
                                        }
                                        if msg.isOut {
                                            Button("Редактировать") {
                                                replyToMessage = nil
                                                editingMessage = msg
                                                draftText = msg.text
                                            }
                                            Button("Удалить", role: .destructive) {
                                                Task {
                                                    await appState.deleteMessage(peerId: peerId, messageId: msg.id)
                                                }
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: appState.messagesByPeer[peerId]?.last?.id) { lastId in
                        if let lastId {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: scrollTargetId) { targetId in
                        if let targetId {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(targetId, anchor: .center)
                            }
                            scrollTargetId = nil
                        }
                    }
                }

                Divider()

                if isSelectionMode && !selectedMessageIds.isEmpty {
                    HStack {
                        Text("Выбрано: \(selectedMessageIds.count)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Переслать") {
                            showBatchForwardSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Удалить", role: .destructive) {
                            let ids = Array(selectedMessageIds)
                            selectedMessageIds.removeAll()
                            isSelectionMode = false
                            Task { await appState.deleteMessagesBatch(peerId: peerId, messageIds: ids) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08))
                }

                if let reply = replyToMessage {
                    composeBanner(
                        title: "Ответ на сообщение",
                        subtitle: reply.text.isEmpty ? "[Вложение]" : reply.text
                    ) {
                        replyToMessage = nil
                    }
                } else if let editing = editingMessage {
                    composeBanner(
                        title: "Редактирование",
                        subtitle: editing.text
                    ) {
                        editingMessage = nil
                        draftText = ""
                    }
                }

                if let photoPath = attachedPhotoPath {
                    composeBanner(
                        title: "Прикреплено фото",
                        subtitle: URL(fileURLWithPath: photoPath).lastPathComponent
                    ) {
                        attachedPhotoPath = nil
                    }
                } else if let docPath = attachedDocPath {
                    composeBanner(
                        title: "Прикреплён файл",
                        subtitle: URL(fileURLWithPath: docPath).lastPathComponent
                    ) {
                        attachedDocPath = nil
                    }
                }

                Group {
                HStack(spacing: 8) {
                    Menu {
                        Button("Фото...") { pickPhotoFile() }
                        Button("Документ / файл...") { pickDocFile() }
                        Button("Вставить фото из буфера (⌘V)") { pasteImageFromClipboard() }
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Прикрепить фото или файл")

                    Button {
                        showStickerPicker.toggle()
                    } label: {
                        Image(systemName: "face.smiling")
                    }
                    .buttonStyle(.bordered)
                    .help("Стикеры")
                    .popover(isPresented: $showStickerPicker) {
                        StickerPickerPopover { stickerId in
                            showStickerPicker = false
                            Task { await appState.sendSticker(peerId: peerId, stickerId: stickerId) }
                        }
                        .environmentObject(appState)
                    }

                    Button {
                        showSnippetsPopover.toggle()
                    } label: {
                        Image(systemName: "text.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .help("Шаблоны ответов")
                    .popover(isPresented: $showSnippetsPopover) {
                        SnippetsPopover { text in
                            draftText = draftText.isEmpty ? text : "\(draftText) \(text)"
                            showSnippetsPopover = false
                        }
                        .environmentObject(appState)
                    }

                    Button {
                        if voiceRecorder.isRecording {
                            if let url = voiceRecorder.stopRecording() {
                                Task { await appState.sendDocMessage(peerId: peerId, filePath: url.path, isAudioMessage: true) }
                            }
                        } else {
                            voiceRecorder.startRecording { errText in
                                appState.errorMessage = errText
                            }
                        }
                    } label: {
                        Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic")
                            .foregroundStyle(voiceRecorder.isRecording ? Color.red : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .help(voiceRecorder.isRecording ? "Остановить запись и отправить" : "Записать голосовое сообщение")

                    TextField("Написать сообщение...", text: $draftText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            sendCurrentDraft(peerId: peerId)
                        }

                    Button {
                        sendCurrentDraft(peerId: peerId)
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        attachedPhotoPath == nil &&
                        attachedDocPath == nil
                    )
                }
                .padding(12)
                .overlay(alignment: .bottom) { EmptyView() }

                if let kb = activeBottomKeyboard(for: peerId) {
                    VStack(spacing: 0) {
                        Divider()
                        BotKeyboardView(
                            rows: kb.rows,
                            peerId: peerId,
                            messageId: kb.messageId,
                            oneTime: kb.oneTime,
                            onDismiss: {
                                appState.conversationKeyboards[peerId] = nil
                                if kb.messageId != 0 {
                                    appState.dismissedKeyboardMessageIds.insert(kb.messageId)
                                }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.06))
                    }
                }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Выберите диалог слева")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func activeBottomKeyboard(for peerId: Int64) -> (messageId: Int64, oneTime: Bool, rows: [BotKeyboardRow])? {
        if let convKb = appState.conversationKeyboards[peerId], !convKb.rows.isEmpty {
            return (0, convKb.oneTime, convKb.rows)
        }
        let msgs = appState.messagesByPeer[peerId] ?? []
        for msg in msgs.reversed() where !msg.isOut {
            if appState.dismissedKeyboardMessageIds.contains(msg.id) { continue }
            for att in msg.attachments {
                if case .botKeyboard(let inline, let oneTime, let rows) = att, !inline, !rows.isEmpty {
                    return (msg.id, oneTime, rows)
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func composeBanner(title: String, subtitle: String, onCancel: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(appState.accentColor)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }

    private func pickPhotoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            attachedPhotoPath = url.path
            attachedDocPath = nil
        }
    }

    private func pickDocFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            attachedDocPath = url.path
            attachedPhotoPath = nil
        }
    }

    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vkmac_paste_\(Int(Date().timeIntervalSince1970)).png")
            if (try? png.write(to: tmp)) != nil {
                attachedPhotoPath = tmp.path
                attachedDocPath = nil
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            let isImg = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext)
            Task { @MainActor in
                if isImg {
                    attachedPhotoPath = url.path
                    attachedDocPath = nil
                } else {
                    attachedDocPath = url.path
                    attachedPhotoPath = nil
                }
            }
        }
        return true
    }

    private func exportCurrentChat(peerId: Int64, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "_")).txt"
        if panel.runModal() == .OK, let url = panel.url {
            _ = appState.exportChatHistory(peerId: peerId, destPath: url.path)
        }
    }

    private func exportCurrentChatHTML(peerId: Int64, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "_")).html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let msgs = (appState.messagesByPeer[peerId] ?? []).sorted { $0.date < $1.date }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font-family:-apple-system,sans-serif;max-width:760px;margin:24px auto;background:#111;color:#eee;}
        .msg{padding:10px 14px;border-radius:12px;margin:8px 0;background:#222;}.out{background:#1c4d8d;}
        .meta{font-size:11px;color:#aaa;margin-bottom:4px;}img{max-width:320px;border-radius:8px;margin-top:6px;display:block;}</style></head><body><h2>\(title)</h2>
        """
        for m in msgs {
            let cls = m.isOut ? "msg out" : "msg"
            let dt = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(m.date)))
            let escaped = m.text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            html += "<div class='\(cls)'><div class='meta'>\(m.isOut ? "Вы" : "Собеседник") · \(dt)</div><div>\(escaped)</div>"
            for att in m.attachments {
                if case .photo(let u, _, _) = att { html += "<img src='\(u)'/>" }
                if case .audioMessage(let u, let d, let tr) = att {
                    html += "<div>🎤 Голосовое (\(d)с): <a href='\(u)'>скачать</a> \(tr ?? "")</div>"
                }
            }
            html += "</div>"
        }
        html += "</body></html>"
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    private func formatLastSeen(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "не в сети" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return "был(а) \(fmt.string(from: date))"
    }

    private func sendCurrentDraft(peerId: Int64) {
        let text = draftText
        let replyId = replyToMessage?.id
        let editing = editingMessage
        let photoPath = attachedPhotoPath
        let docPath = attachedDocPath

        draftText = ""
        replyToMessage = nil
        editingMessage = nil
        attachedPhotoPath = nil
        attachedDocPath = nil
        appState.saveDraft(peerId: peerId, text: "")

        Task {
            if let editing {
                await appState.editMessage(peerId: peerId, messageId: editing.id, text: text)
            } else if let docPath {
                await appState.sendDocMessage(peerId: peerId, filePath: docPath, text: text, isAudioMessage: false)
            } else if replyId != nil || photoPath != nil {
                await appState.sendMessageWithOptions(
                    peerId: peerId,
                    text: text,
                    replyTo: replyId,
                    photoPath: photoPath
                )
            } else {
                await appState.sendMessage(peerId: peerId, text: text)
            }
        }
    }
}

private struct ConversationRow: View {
    @EnvironmentObject private var appState: AppState
    let conversation: ConversationItem
    var isPinned: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(urlString: conversation.avatarUrl, title: conversation.title, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(appState.accentColor)
                    }
                    Text(conversation.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(formatDate(conversation.lastMessageDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(conversation.lastMessageText.isEmpty ? " " : conversation.lastMessageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(conversation.isMuted ? Color.secondary : appState.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var appState: AppState
    let message: MessageItem
    var onScrollToMessage: ((Int64) -> Void)? = nil

    var body: some View {
        HStack {
            if message.isOut { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                }

                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    attachmentView(attachment)
                }

                Text(formatTime(message.date))
                    .font(.caption2)
                    .foregroundStyle(message.isOut ? Color.white.opacity(0.75) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(message.isOut ? appState.accentColor : Color.secondary.opacity(0.15))
            .foregroundStyle(message.isOut ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if !message.isOut { Spacer(minLength: 60) }
        }
    }

    @MainActor
    @ViewBuilder
    private func attachmentView(_ attachment: Attachment) -> some View {
        switch attachment {
        case .photo(let urlStr, _, _):
            if let url = URL(string: urlStr) {
                Button {
                    let photoUrls = message.attachments.compactMap { att -> String? in
                        if case .photo(let u, _, _) = att { return u }
                        return nil
                    }
                    let idx = photoUrls.firstIndex(of: urlStr) ?? 0
                    PhotoViewerWindow.shared.show(urls: photoUrls, initialIndex: idx)
                } label: {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onDrag { NSItemProvider(object: url as NSURL) }
            }
        case .sticker(let urlStr):
            if let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 128, height: 128)
            }
        case .audio(let artist, let title, _, _):
            Label("\(artist) — \(title)", systemImage: "music.note")
                .font(.caption)
        case .document(let title, let urlStr, let ext):
            Button {
                downloadAndRevealDocument(title: title, urlStr: urlStr, ext: ext)
            } label: {
                Label("\(title) (.\(ext))", systemImage: "doc.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        case .link(let title, let urlStr):
            VStack(alignment: .leading, spacing: 4) {
                if let url = URL(string: urlStr) {
                    Link(destination: url) {
                        Label(title.isEmpty ? urlStr : title, systemImage: "link")
                            .font(.caption)
                            .underline()
                    }
                    RichLinkPreview(url: url)
                } else {
                    Label(title.isEmpty ? urlStr : title, systemImage: "link")
                        .font(.caption)
                }
            }
        case .video(let vidId, let vidOwnerId, let accessKey, let title, _, let thumbUrl, let playerUrl, let streamUrl, let qualities):
            VStack(alignment: .leading, spacing: 4) {
                if let thumbUrl, let url = URL(string: thumbUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(width: 220, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle.fill")
                    Text(title)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            .onTapGesture {
                PhotoViewerWindow.shared.showMedia(
                    [.video(id: vidId, ownerId: vidOwnerId, accessKey: accessKey, title: title, streamUrl: streamUrl, playerUrl: playerUrl, thumbnailUrl: thumbUrl, qualities: qualities)],
                    initialIndex: 0
                )
            }
        case .audioMessage(let urlStr, let durationSec, let transcript):
            InlineVoicePlayer(urlString: urlStr, durationSec: durationSec, transcript: transcript)
        case .poll(_, _, let question, let answers):
            let totalVotes = answers.reduce(0) { $0 + $1.votes }
            Label("Опрос: \(question) (\(totalVotes))", systemImage: "chart.bar.xaxis")
                .font(.caption)
        case .reply(let messageId, let text):
            Button {
                onScrollToMessage?(messageId)
            } label: {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(message.isOut ? Color.white.opacity(0.8) : appState.accentColor)
                        .frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ответ")
                            .font(.caption2.bold())
                        Text(text)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        case .forwarded(let fromName, let text, _):
            HStack(spacing: 6) {
                Rectangle()
                    .fill(message.isOut ? Color.white.opacity(0.7) : appState.accentColor)
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Переслано от \(fromName)")
                        .font(.caption2.bold())
                    Text(text)
                        .font(.caption)
                }
            }
            .padding(6)
            .background(Color.black.opacity(message.isOut ? 0.15 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .botKeyboard(let inline, let oneTime, let rows):
            if inline {
                BotKeyboardView(
                    rows: rows,
                    peerId: message.peerId,
                    messageId: message.id,
                    oneTime: oneTime,
                    onDismiss: nil
                )
                .padding(.top, 4)
            }
        case .unknown(let kind):
            Text("[\(kind)]")
                .font(.caption)
                .opacity(0.8)
        }
    }

    private func formatTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func downloadAndRevealDocument(title: String, urlStr: String, ext: String) {
        guard let url = URL(string: urlStr) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let safeName = title.replacingOccurrences(of: "/", with: "_")
            let fileName = safeName.hasSuffix(".\(ext)") || ext.isEmpty ? safeName : "\(safeName).\(ext)"
            let dest = downloads.appendingPathComponent(fileName)
            if (try? data.write(to: dest)) != nil {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            }
        }
    }
}

struct AvatarView: View {
    let urlString: String?
    let title: String
    let size: CGFloat

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                initialsView
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.2))
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
private final class VoiceRecorderHelper: ObservableObject {
    @Published var isRecording = false
    private var recorder: AVAudioRecorder?
    private var outputUrl: URL?

    func startRecording(onError: @escaping (String) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            beginRecording(onError: onError)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.beginRecording(onError: onError)
                    } else {
                        onError("Доступ к микрофону запрещён в Настройках macOS")
                    }
                }
            }
        case .denied, .restricted:
            onError("Нет доступа к микрофону. Разрешите доступ для VKMac в Системных настройках → Конфиденциальность → Микрофон.")
        @unknown default:
            onError("Микрофон недоступен")
        }
    }

    private func beginRecording(onError: (String) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vkmac_voice_\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.prepareToRecord(), rec.record() else {
                onError("Не удалось начать запись с микрофона")
                return
            }
            recorder = rec
            outputUrl = url
            isRecording = true
        } catch {
            onError("Ошибка микрофона: \(error.localizedDescription)")
        }
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url = outputUrl,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 44 else {
            return nil
        }
        return url
    }
}

@MainActor
private final class VoicePlayerManager: ObservableObject {
    static let shared = VoicePlayerManager()
    @Published var playingUrl: String?
    @Published var errorText: String?
    @Published var rate: Float = 1.0

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    func cycleRate() {
        let next: Float = rate < 1.4 ? 1.5 : (rate < 1.9 ? 2.0 : 1.0)
        rate = next
        if playingUrl != nil {
            player?.rate = next
        }
    }

    func toggle(urlString: String) {
        if playingUrl == urlString {
            stop()
            return
        }
        stop()
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            errorText = "Ссылка на голосовое недоступна"
            return
        }
        if AudioPlayerService.shared.isPlaying {
            AudioPlayerService.shared.togglePlayPause()
        }
        errorText = nil
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "VKAndroidApp/8.44-18440 (Android 13; SDK 33; arm64-v8a; Pixel 7; ru)"
                ]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor [weak self] in
                if it.status == .failed {
                    self?.errorText = it.error?.localizedDescription ?? "Ошибка воспроизведения"
                    self?.playingUrl = nil
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playingUrl = nil
            }
        }
        player = p
        playingUrl = urlString
        p.play()
        p.rate = rate
    }

    func stop() {
        player?.pause()
        player = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playingUrl = nil
    }
}

private struct InlineVoicePlayer: View {
    let urlString: String
    let durationSec: UInt32
    var transcript: String? = nil
    @ObservedObject private var manager = VoicePlayerManager.shared

    private var isPlaying: Bool {
        manager.playingUrl == urlString && !urlString.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    manager.toggle(urlString: urlString)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(urlString.isEmpty)

                Image(systemName: "waveform")
                Text("\(durationSec) с")
                    .font(.caption)

                Button {
                    manager.cycleRate()
                } label: {
                    Text("\(String(format: "%.2gx", manager.rate))")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if let transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .opacity(0.9)
                    .textSelection(.enabled)
            }
            if let err = manager.errorText, manager.playingUrl == nil {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct StickerPickerPopover: View {
    @EnvironmentObject private var appState: AppState
    let onSelect: (Int64) -> Void
    @State private var selectedPackId: Int64?

    private var currentPack: StickerPack? {
        if let id = selectedPackId, let found = appState.stickerPacks.first(where: { $0.id == id }) {
            return found
        }
        return appState.stickerPacks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Стикеры")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await appState.loadStickerPacks(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить наборы стикеров")
            }

            if appState.isLoadingStickers && appState.stickerPacks.isEmpty {
                ProgressView("Загрузка стикеров...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.stickerPacks.isEmpty {
                Text("Нет доступных стикеров")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(appState.stickerPacks, id: \.id) { pack in
                            let isSelected = currentPack?.id == pack.id
                            Button {
                                selectedPackId = pack.id
                            } label: {
                                if let iconStr = pack.iconUrl ?? pack.stickers.first?.url, let url = URL(string: iconStr) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img.resizable().scaledToFit()
                                        case .failure:
                                            if let fallback = pack.stickers.first?.url, fallback != iconStr, let fbUrl = URL(string: fallback) {
                                                AsyncImage(url: fbUrl) { fbImg in
                                                    fbImg.resizable().scaledToFit()
                                                } placeholder: {
                                                    Text(String(pack.title.prefix(2)))
                                                        .font(.caption2.bold())
                                                }
                                            } else {
                                                Text(String(pack.title.prefix(2)))
                                                    .font(.caption2.bold())
                                            }
                                        default:
                                            Color.secondary.opacity(0.15)
                                        }
                                    }
                                    .frame(width: 28, height: 28)
                                } else {
                                    Text(String(pack.title.prefix(2)))
                                        .font(.caption2.bold())
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .background(isSelected ? appState.accentColor.opacity(0.22) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(pack.title)
                        }
                    }
                }

                Divider()

                if let pack = currentPack {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                            ForEach(pack.stickers, id: \.stickerId) { sticker in
                                Button {
                                    onSelect(sticker.stickerId)
                                } label: {
                                    AsyncImage(url: URL(string: sticker.url)) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: {
                                        Color.secondary.opacity(0.12)
                                    }
                                    .frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 340)
        .task {
            await appState.loadStickerPacks()
            if selectedPackId == nil {
                selectedPackId = appState.stickerPacks.first?.id
            }
        }
    }
}

private struct ForwardMessageSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let message: MessageItem
    let onSelectPeer: (Int64) -> Void
    @State private var filter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Переслать сообщение")
                    .font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            TextField("Поиск диалога...", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(filtered, id: \.peerId) { conv in
                Button {
                    onSelectPeer(conv.peerId)
                } label: {
                    HStack {
                        AvatarView(urlString: conv.avatarUrl, title: conv.title, size: 28)
                        Text(conv.title)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
    }

    private var filtered: [ConversationItem] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return appState.conversations }
        return appState.conversations.filter { $0.title.lowercased().contains(q) }
    }
}

private struct ChatInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let peerId: Int64
    let members: [ChatMember]
    @Binding var title: String
    let onSaveTitle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Информация о беседе")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            HStack {
                TextField("Название беседы", text: $title)
                    .textFieldStyle(.roundedBorder)
                Button("Сохранить", action: onSaveTitle)
                    .buttonStyle(.borderedProminent)
            }
            Text("Участники (\(members.count))")
                .font(.subheadline.weight(.semibold))
            List(members, id: \.id) { m in
                HStack(spacing: 10) {
                    AvatarView(urlString: m.avatarUrl, title: m.name, size: 28)
                    Text(m.name)
                    Spacer()
                    if m.isAdmin {
                        Text("Админ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400, height: 440)
    }
}

private struct RichLinkPreview: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?

    var body: some View {
        Group {
            if let meta = metadata, let title = meta.title, !title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(2)
                    if let host = url.host {
                        Text(host)
                            .font(.caption2)
                            .opacity(0.75)
                    }
                }
                .padding(6)
                .background(Color.black.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: url) {
            let provider = LPMetadataProvider()
            metadata = try? await provider.startFetchingMetadata(for: url)
        }
    }
}

private struct ChatAttachmentsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let peerId: Int64

    @State private var kind: String = "photo"
    @State private var items: [Attachment] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Вложения диалога")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            Picker("", selection: $kind) {
                Text("Фото").tag("photo")
                Text("Видео").tag("video")
                Text("Файлы").tag("doc")
                Text("Ссылки").tag("link")
                Text("Аудио").tag("audio")
            }
            .pickerStyle(.segmented)

            if isLoading {
                ProgressView("Загрузка...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("Нет вложений этого типа")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(items.enumerated()), id: \.offset) { _, att in
                    switch att {
                    case .photo(let urlStr, _, _):
                        Button {
                            PhotoViewerWindow.shared.show(urls: [urlStr], initialIndex: 0)
                        } label: {
                            HStack {
                                AsyncImage(url: URL(string: urlStr)) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Color.secondary.opacity(0.2) }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("Фото")
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    case .video(let vid, let oid, let ak, let title, _, let thumb, let player, let stream, let q):
                        Button {
                            PhotoViewerWindow.shared.showMedia([.video(id: vid, ownerId: oid, accessKey: ak, title: title, streamUrl: stream, playerUrl: player, thumbnailUrl: thumb, qualities: q)], initialIndex: 0)
                        } label: {
                            Label(title, systemImage: "play.rectangle")
                        }
                        .buttonStyle(.plain)
                    case .document(let title, let urlStr, let ext):
                        if let url = URL(string: urlStr) {
                            Link(destination: url) {
                                Label("\(title) (.\(ext))", systemImage: "doc")
                            }
                        }
                    case .link(let title, let urlStr):
                        if let url = URL(string: urlStr) {
                            Link(destination: url) {
                                Label(title.isEmpty ? urlStr : title, systemImage: "link")
                            }
                        }
                    case .audio(let artist, let title, _, _):
                        Label("\(artist) — \(title)", systemImage: "music.note")
                    default:
                        Text("Вложение")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 480)
        .task(id: kind) {
            isLoading = true
            items = await appState.getHistoryAttachments(peerId: peerId, mediaType: kind)
            isLoading = false
        }
    }
}

private struct ForwardMultipleSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let onSelectPeer: (Int64) -> Void
    @State private var filter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Переслать (\(count))")
                    .font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }
            }
            TextField("Поиск диалога...", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(appState.conversations.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }, id: \.peerId) { conv in
                Button {
                    onSelectPeer(conv.peerId)
                } label: {
                    HStack {
                        AvatarView(urlString: conv.avatarUrl, title: conv.title, size: 28)
                        Text(conv.title)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
    }
}

private struct SnippetsPopover: View {
    @EnvironmentObject private var appState: AppState
    let onInsert: (String) -> Void
    @State private var newTitle: String = ""
    @State private var newText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Быстрые шаблоны")
                .font(.headline)
            if appState.snippets.isEmpty {
                Text("Пока нет шаблонов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(appState.snippets, id: \.id) { s in
                    HStack {
                        Button {
                            onInsert(s.text)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.title).font(.caption.weight(.semibold))
                                Text(s.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            appState.deleteSnippet(id: s.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(height: 150)
            }
            Divider()
            TextField("Название", text: $newTitle)
                .textFieldStyle(.roundedBorder)
            TextField("Текст шаблона", text: $newText)
                .textFieldStyle(.roundedBorder)
            Button("Добавить шаблон") {
                guard !newTitle.isEmpty, !newText.isEmpty else { return }
                appState.saveSnippet(title: newTitle, text: newText)
                newTitle = ""
                newText = ""
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct BotKeyboardView: View {
    @EnvironmentObject private var appState: AppState
    let rows: [BotKeyboardRow]
    let peerId: Int64
    let messageId: Int64
    let oneTime: Bool
    let onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            if let onDismiss {
                HStack {
                    Text("Клавиатура бота")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Скрыть клавиатуру")
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.buttons.enumerated()), id: \.offset) { _, btn in
                        Button {
                            Task {
                                await appState.sendBotButton(
                                    peerId: peerId,
                                    messageId: messageId,
                                    oneTime: oneTime,
                                    button: btn
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(btn.label)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if btn.actionType == "open_link" {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(buttonBackground(btn.color))
                            .foregroundStyle(buttonForeground(btn.color))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func buttonBackground(_ color: String) -> Color {
        switch color {
        case "primary": return appState.accentColor
        case "positive": return Color.green.opacity(0.85)
        case "negative": return Color.red.opacity(0.85)
        default: return Color.secondary.opacity(0.18)
        }
    }

    private func buttonForeground(_ color: String) -> Color {
        switch color {
        case "primary", "positive", "negative": return .white
        default: return .primary
        }
    }
}
