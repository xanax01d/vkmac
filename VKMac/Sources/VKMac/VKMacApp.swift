import AppKit
import Carbon
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var appState: AppState?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        UNUserNotificationCenter.current().delegate = self
        registerGlobalHotKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            guard let appState else { return }
            let raw = url.absoluteString.replacingOccurrences(of: "vk://", with: "https://")
            if let httpsUrl = URL(string: raw) {
                _ = VkLinkHandler.handle(httpsUrl, appState: appState)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "REPLY_ACTION",
           let textResp = response as? UNTextInputNotificationResponse,
           let peerId = response.notification.request.content.userInfo["peerId"] as? Int64 {
            let replyText = textResp.userText
            Task { @MainActor [weak self] in
                await self?.appState?.sendMessage(peerId: peerId, text: replyText)
            }
        }
        completionHandler()
    }

    private func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x564B4D43, id: 1) // 'VKMC'
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                if NSApp.isActive {
                    NSApp.hide(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
            }
            return noErr
        }, 1, &eventSpec, nil, nil)
        // Option + Space (keyCode 49 = Space, optionKey = 2048)
        RegisterEventHotKey(49, UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let chatsItem = NSMenuItem(title: "Открыть Чаты", action: #selector(dockOpenChats), keyEquivalent: "")
        chatsItem.target = self
        menu.addItem(chatsItem)

        let playItem = NSMenuItem(
            title: AudioPlayerService.shared.isPlaying ? "Пауза" : "Воспроизвести",
            action: #selector(dockTogglePlay),
            keyEquivalent: ""
        )
        playItem.target = self
        menu.addItem(playItem)

        let nextItem = NSMenuItem(title: "Следующий трек", action: #selector(dockNextTrack), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        let stealthItem = NSMenuItem(
            title: appState?.stealthMode == true ? "Выключить тихое чтение" : "Тихое чтение",
            action: #selector(dockToggleStealth),
            keyEquivalent: ""
        )
        stealthItem.target = self
        menu.addItem(stealthItem)
        return menu
    }

    @objc private func dockOpenChats() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            appState?.selectedTab = .chats
        }
    }

    @objc private func dockTogglePlay() {
        Task { @MainActor in
            AudioPlayerService.shared.togglePlayPause()
        }
    }

    @objc private func dockNextTrack() {
        Task { @MainActor in
            AudioPlayerService.shared.nextTrack()
        }
    }

    @objc private func dockToggleStealth() {
        Task { @MainActor in
            guard let appState else { return }
            appState.stealthMode.toggle()
            appState.savePref(key: "stealthMode", value: appState.stealthMode ? "1" : "0")
            TouchBarController.shared.refresh()
        }
    }
}

@main
struct VKMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var audioPlayer = AudioPlayerService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(audioPlayer)
                .tint(appState.accentColor)
                .accentColor(appState.accentColor)
                .frame(minWidth: 900, minHeight: 620)
                .onChange(of: audioPlayer.isPlaying) { _ in
                    TouchBarController.shared.refresh()
                }
                .onChange(of: audioPlayer.currentTrack?.id) { _ in
                    TouchBarController.shared.refresh()
                }
                .onChange(of: Int(audioPlayer.currentTime)) { _ in
                    TouchBarController.shared.updateProgress(
                        currentTime: audioPlayer.currentTime,
                        duration: audioPlayer.duration
                    )
                }
                .environment(\.openURL, OpenURLAction { url in
                    VkLinkHandler.handle(url, appState: appState)
                })
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willMiniaturizeNotification)) { _ in
                    if appState.touchIdEnabled && appState.autoLockOnMinimize {
                        appState.isLocked = true
                    }
                }
                .task {
                    appDelegate.appState = appState
                    await appState.bootstrap()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandMenu("Навигация") {
                Button("Палитра команд") {
                    appState.showCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Заблокировать VKMac") {
                    appState.isLocked = true
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Group {
                    Button("Моя страница") { appState.selectedTab = .myPage }
                        .keyboardShortcut("1", modifiers: [.command])
                    Button("Чаты") { appState.selectedTab = .chats }
                        .keyboardShortcut("2", modifiers: [.command])
                    Button("Лента") { appState.selectedTab = .feed }
                        .keyboardShortcut("3", modifiers: [.command])
                    Button("Закладки") { appState.selectedTab = .fave }
                        .keyboardShortcut("4", modifiers: [.command])
                    Button("Уведомления") { appState.selectedTab = .notifications }
                        .keyboardShortcut("5", modifiers: [.command])
                }

                Group {
                    Button("Друзья") { appState.selectedTab = .friends }
                        .keyboardShortcut("6", modifiers: [.command])
                    Button("Группы") { appState.selectedTab = .groups }
                        .keyboardShortcut("7", modifiers: [.command])
                    Button("Видео") { appState.selectedTab = .videos }
                        .keyboardShortcut("8", modifiers: [.command])
                    Button("Музыка") { appState.selectedTab = .music }
                        .keyboardShortcut("9", modifiers: [.command])
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("О программе VKMac") {
                    AboutWindow.shared.show()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Справка VKMac") {
                    appState.selectedTab = .help
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.totalUnreadCount > 0 ? "Непрочитанных: \(appState.totalUnreadCount)" : "Нет новых сообщений")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                if let track = audioPlayer.currentTrack {
                    Divider()
                    Text("\(track.artist) — \(track.title)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                    HStack {
                        Button(audioPlayer.isPlaying ? "Пауза" : "Играть") {
                            audioPlayer.togglePlayPause()
                        }
                        Button("Следующий") {
                            audioPlayer.nextTrack()
                        }
                    }
                    .padding(.horizontal, 8)
                }

                Divider()
                Button("Открыть Чаты") {
                    NSApp.activate(ignoringOtherApps: true)
                    appState.selectedTab = .chats
                }
                Button("Открыть Музыку") {
                    NSApp.activate(ignoringOtherApps: true)
                    appState.selectedTab = .music
                }
                Divider()
                Button("Выход") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Image(nsImage: Self.menuBarImage(unreadCount: appState.totalUnreadCount))
        }
    }

    private static let rawMenuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        img.size = NSSize(width: 20, height: 12)
        img.isTemplate = true
        return img
    }()

    private static func menuBarImage(unreadCount: UInt32) -> NSImage {
        let iconSize = NSSize(width: 20, height: 12)
        let barHeight: CGFloat = 18

        let countStr: NSAttributedString? = unreadCount > 0 ? NSAttributedString(
            string: "\(unreadCount)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        ) : nil

        let spacing: CGFloat = countStr != nil ? 4 : 0
        let textSize = countStr?.size() ?? .zero
        let totalWidth = iconSize.width + spacing + textSize.width

        let canvas = NSImage(size: NSSize(width: totalWidth, height: barHeight))
        canvas.lockFocus()

        if let icon = rawMenuBarIcon {
            let iconRect = NSRect(
                x: 0,
                y: (barHeight - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            icon.draw(in: iconRect)
        }
        if let countStr {
            let textRect = NSRect(
                x: iconSize.width + spacing,
                y: (barHeight - textSize.height) / 2 - 0.5,
                width: textSize.width,
                height: textSize.height
            )
            countStr.draw(in: textRect)
        }

        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isLocked {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(appState.accentColor)
                Text("VKMac заблокирован")
                    .font(.title2.weight(.semibold))
                Button("Разблокировать с Touch ID / паролем") {
                    appState.unlockWithTouchID()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                appState.unlockWithTouchID()
            }
        } else {
            switch appState.authState {
            case .authenticated:
                MainSplitView()
            case .loggedOut, .needs2Fa, .needsCaptcha:
                AuthView()
            }
        }
    }
}

@MainActor
private final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "О программе VKMac"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentViewController = NSHostingController(rootView: AboutView())
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("VKMac")
                .font(.title2.bold())

            Text("Версия 1.0.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("© 2026 Zaharia Klimkovich (xanax01d)\nНативный клиент ВКонтакте для macOS (MIT)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let url = URL(string: "https://github.com/xanax01d/vkmac") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Открыть на GitHub", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 340, height: 270)
    }
}
