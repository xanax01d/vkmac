import AppKit
import Foundation

final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarController()

    private weak var appState: AppState?
    private weak var audioPlayer: AudioPlayerService?

    private var selectedTab: SidebarTab = .chats
    private var unreadCount: UInt32 = 0
    private var isPlaying: Bool = false
    private var stealthMode: Bool = false
    private var touchIdEnabled: Bool = false
    private var hasPresentedPost: Bool = false
    private var currentTrackTitle: String = ""
    private var currentTrackOwnerId: Int64 = 0
    private var currentTrackId: Int64 = 0
    private var currentTime: Double = 0
    private var duration: Double = 1
    private var volume: Float = 1.0
    private var infiniteWave: Bool = false

    private var activePopoverItem: NSPopoverTouchBarItem?
    private weak var activeScrubberView: TouchBarScrubberView?

    @MainActor
    func updateProgress(currentTime: Double, duration: Double) {
        self.currentTime = currentTime
        self.duration = max(duration, 1)
        activeScrubberView?.update(currentTime: self.currentTime, duration: self.duration)
    }

    private enum ItemID {
        static let chats = NSTouchBarItem.Identifier("com.vkmac.tb.chats")
        static let feed = NSTouchBarItem.Identifier("com.vkmac.tb.feed")
        static let music = NSTouchBarItem.Identifier("com.vkmac.tb.music")
        static let back = NSTouchBarItem.Identifier("com.vkmac.tb.back")
        static let prev = NSTouchBarItem.Identifier("com.vkmac.tb.prev")
        static let trackPopover = NSTouchBarItem.Identifier("com.vkmac.tb.trackpopover")
        static let next = NSTouchBarItem.Identifier("com.vkmac.tb.next")
        static let contextScroll = NSTouchBarItem.Identifier("com.vkmac.tb.contextscroll")

        // Popover items (при зажатии на название трека)
        static let popScrub = NSTouchBarItem.Identifier("com.vkmac.tb.pop.scrub")
        static let popVolume = NSTouchBarItem.Identifier("com.vkmac.tb.pop.vol")
        static let popAdd = NSTouchBarItem.Identifier("com.vkmac.tb.pop.add")
        static let popWave = NSTouchBarItem.Identifier("com.vkmac.tb.pop.wave")
    }

    @MainActor
    func attach(appState: AppState, audioPlayer: AudioPlayerService) {
        self.appState = appState
        self.audioPlayer = audioPlayer
        refresh()
    }

    @MainActor
    func refresh() {
        if let appState {
            selectedTab = appState.selectedTab
            unreadCount = appState.totalUnreadCount
            stealthMode = appState.stealthMode
            touchIdEnabled = appState.touchIdEnabled
            hasPresentedPost = appState.presentedPost != nil
            infiniteWave = appState.infiniteWave
        }
        if let audioPlayer {
            isPlaying = audioPlayer.isPlaying
            currentTime = audioPlayer.currentTime
            duration = max(audioPlayer.duration, 1)
            volume = audioPlayer.volume
            if let t = audioPlayer.currentTrack {
                currentTrackTitle = "\(t.artist) — \(t.title)"
                currentTrackOwnerId = t.ownerId
                currentTrackId = t.id
            } else {
                currentTrackTitle = ""
                currentTrackOwnerId = 0
                currentTrackId = 0
            }
        }
        let bar = makeMainTouchBar()
        for win in NSApp.windows where win.title != "PhotoViewer" {
            win.touchBar = bar
        }
    }

    private func makeMainTouchBar() -> NSTouchBar {
        let tb = NSTouchBar()
        tb.delegate = self
        let leftItem = hasPresentedPost ? ItemID.back : ItemID.chats
        if currentTrackTitle.isEmpty {
            tb.defaultItemIdentifiers = [
                leftItem,
                ItemID.feed,
                ItemID.music,
                ItemID.contextScroll
            ]
        } else {
            tb.defaultItemIdentifiers = [
                leftItem,
                ItemID.prev,
                ItemID.trackPopover,
                ItemID.next,
                ItemID.contextScroll
            ]
        }
        return tb
    }

    private func makeTrackPopoverTouchBar() -> NSTouchBar {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [
            ItemID.popScrub,
            ItemID.popVolume,
            ItemID.popAdd,
            ItemID.popWave
        ]
        return tb
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case ItemID.chats:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let title = unreadCount > 0 ? "Чаты (\(unreadCount))" : "Чаты"
            let btn = NSButton(title: title, target: self, action: #selector(onChats))
            if selectedTab == .chats { btn.bezelColor = NSColor.controlAccentColor }
            item.view = btn
            return item

        case ItemID.feed:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let btn = NSButton(title: "Лента", target: self, action: #selector(onFeed))
            if selectedTab == .feed { btn.bezelColor = NSColor.controlAccentColor }
            item.view = btn
            return item

        case ItemID.music:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let btn = NSButton(title: "Музыка", target: self, action: #selector(onMusic))
            if selectedTab == .music { btn.bezelColor = NSColor.controlAccentColor }
            item.view = btn
            return item

        case ItemID.back:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let btn = NSButton(title: "← Назад", target: self, action: #selector(onBackFromPost))
            item.view = btn
            return item

        case ItemID.contextScroll:
            let item = NSCustomTouchBarItem(identifier: identifier)
            var views: [NSView] = []

            if hasPresentedPost {
                views.append(NSButton(title: "❤️ Лайк", target: self, action: #selector(onLikeCurrentPost)))
                views.append(NSButton(title: "Поделиться", target: self, action: #selector(onRepostCurrentPost)))
                views.append(NSButton(title: "В закладки", target: self, action: #selector(onBookmarkCurrentPost)))
            } else {
                switch selectedTab {
                case .chats:
                    views.append(NSButton(title: "❤️", target: self, action: #selector(onQuickHeart)))
                    views.append(NSButton(title: "👍", target: self, action: #selector(onQuickThumb)))
                    views.append(NSButton(title: "😂", target: self, action: #selector(onQuickLaugh)))
                case .feed:
                    let refreshImg = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Обновить") ?? NSImage()
                    views.append(NSButton(image: refreshImg, target: self, action: #selector(onRefreshFeed)))
                case .music:
                    let plusImg = NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить") ?? NSImage()
                    views.append(NSButton(image: plusImg, target: self, action: #selector(onAddTrack)))
                    let waveImg = NSImage(systemSymbolName: "infinity", accessibilityDescription: "Волна") ?? NSImage()
                    let waveBtn = NSButton(image: waveImg, target: self, action: #selector(onToggleWave))
                    if infiniteWave { waveBtn.bezelColor = NSColor.controlAccentColor }
                    views.append(waveBtn)
                    let castImg = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "В статус") ?? NSImage()
                    views.append(NSButton(image: castImg, target: self, action: #selector(onBroadcastTrack)))
                default:
                    views.append(NSButton(title: "Лента", target: self, action: #selector(onFeed)))
                    views.append(NSButton(title: "Музыка", target: self, action: #selector(onMusic)))
                }
            }

            let stealthImg = NSImage(systemSymbolName: stealthMode ? "eye.slash.fill" : "eye", accessibilityDescription: "Тихое чтение") ?? NSImage()
            let stealthBtn = NSButton(image: stealthImg, target: self, action: #selector(onStealth))
            if stealthMode { stealthBtn.bezelColor = NSColor.systemOrange }
            views.append(stealthBtn)

            let searchImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Команды") ?? NSImage()
            views.append(NSButton(image: searchImg, target: self, action: #selector(onPalette)))

            if touchIdEnabled {
                let lockImg = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Блокировка") ?? NSImage()
                views.append(NSButton(image: lockImg, target: self, action: #selector(onLock)))
            }

            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false

            let scrollView = NSScrollView()
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.drawsBackground = false
            scrollView.documentView = stack
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let fitWidth = scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor)
            fitWidth.priority = .defaultHigh
            let maxScrollWidth: CGFloat = currentTrackTitle.isEmpty ? 460 : 210

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
                stack.heightAnchor.constraint(equalToConstant: 30),
                scrollView.heightAnchor.constraint(equalToConstant: 30),
                fitWidth,
                scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: maxScrollWidth)
            ])
            item.view = scrollView
            return item

        case ItemID.prev:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let img = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Назад") ?? NSImage()
            item.view = NSButton(image: img, target: self, action: #selector(onPrev))
            return item

        case ItemID.trackPopover:
            let pop = NSPopoverTouchBarItem(identifier: identifier)
            let iconPrefix = isPlaying ? "⏸ " : "▶ "
            let shortTitle = currentTrackTitle.count > 22
                ? String(currentTrackTitle.prefix(21)) + "…"
                : currentTrackTitle

            let trackView = TouchBarTrackView(
                title: iconPrefix + shortTitle,
                onTap: { [weak self] in
                    self?.onPlayPause()
                },
                onHold: { [weak pop] in
                    pop?.showPopover(nil)
                }
            )

            pop.collapsedRepresentation = trackView
            pop.popoverTouchBar = makeTrackPopoverTouchBar()
            pop.showsCloseButton = true
            activePopoverItem = pop
            return pop

        case ItemID.next:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let img = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Вперёд") ?? NSImage()
            item.view = NSButton(image: img, target: self, action: #selector(onNext))
            return item

        case ItemID.popScrub:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrub = TouchBarScrubberView(
                currentTime: currentTime,
                duration: duration,
                onSeek: { [weak self] secs in
                    Task { @MainActor in
                        self?.audioPlayer?.seek(to: secs)
                    }
                }
            )
            activeScrubberView = scrub
            item.view = scrub
            return item

        case ItemID.popVolume:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let volView = TouchBarVolumeView(volume: volume) { [weak self] vol in
                Task { @MainActor in
                    self?.audioPlayer?.volume = vol
                }
            }
            item.view = volView
            return item

        case ItemID.popAdd:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let img = NSImage(systemSymbolName: "plus", accessibilityDescription: "В мои треки") ?? NSImage()
            item.view = NSButton(image: img, target: self, action: #selector(onAddTrack))
            return item

        case ItemID.popWave:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let img = NSImage(systemSymbolName: "infinity", accessibilityDescription: "Волна") ?? NSImage()
            let btn = NSButton(image: img, target: self, action: #selector(onToggleWave))
            if infiniteWave { btn.bezelColor = NSColor.controlAccentColor }
            item.view = btn
            return item

        default:
            return nil
        }
    }

    @objc private func onTrackHold(_ gesture: NSPressGestureRecognizer) {
        if gesture.state == .began {
            activePopoverItem?.showPopover(nil)
        }
    }

    @objc private func onScrub(_ sender: NSSliderTouchBarItem) {
        let secs = sender.slider.doubleValue
        Task { @MainActor in
            audioPlayer?.seek(to: secs)
        }
    }

    @objc private func onVolume(_ sender: NSSliderTouchBarItem) {
        let vol = sender.slider.floatValue
        Task { @MainActor in
            audioPlayer?.volume = vol
        }
    }

    @objc private func onAddTrack() {
        let ownerId = currentTrackOwnerId
        let audioId = currentTrackId
        guard audioId > 0 else { return }
        Task { @MainActor in
            _ = await appState?.addAudio(ownerId: ownerId, audioId: audioId)
        }
    }

    @objc private func onToggleWave() {
        Task { @MainActor in
            guard let appState else { return }
            appState.infiniteWave.toggle()
            appState.savePref(key: "infiniteWave", value: appState.infiniteWave ? "1" : "0")
            refresh()
        }
    }

    @objc private func onChats() {
        Task { @MainActor in
            appState?.presentedPost = nil
            appState?.selectedTab = .chats
            refresh()
        }
    }

    @objc private func onFeed() {
        Task { @MainActor in
            appState?.presentedPost = nil
            appState?.selectedTab = .feed
            refresh()
        }
    }

    @objc private func onPrev() {
        Task { @MainActor in
            audioPlayer?.previousTrack()
            refresh()
        }
    }

    @objc private func onPlayPause() {
        Task { @MainActor in
            audioPlayer?.togglePlayPause()
            refresh()
        }
    }

    @objc private func onNext() {
        Task { @MainActor in
            audioPlayer?.nextTrack()
            refresh()
        }
    }

    @objc private func onPalette() {
        Task { @MainActor in
            appState?.showCommandPalette.toggle()
        }
    }

    @objc private func onBackFromPost() {
        Task { @MainActor in
            appState?.presentedPost = nil
            refresh()
        }
    }

    @objc private func onLikeCurrentPost() {
        Task { @MainActor in
            guard let post = appState?.presentedPost else { return }
            await appState?.toggleLike(post: post)
        }
    }

    @objc private func onRepostCurrentPost() {
        Task { @MainActor in
            guard let post = appState?.presentedPost else { return }
            await appState?.repostPost(post: post)
        }
    }

    @objc private func onBookmarkCurrentPost() {
        Task { @MainActor in
            guard let post = appState?.presentedPost else { return }
            await appState?.addBookmark(ownerId: post.sourceId, postId: post.postId)
        }
    }

    @objc private func onRefreshFeed() {
        Task { @MainActor in
            await appState?.loadFeed(reset: true)
        }
    }

    @objc private func onMusic() {
        Task { @MainActor in
            appState?.presentedPost = nil
            appState?.selectedTab = .music
            refresh()
        }
    }

    @objc private func onBroadcastTrack() {
        let oid = currentTrackOwnerId
        let aid = currentTrackId
        guard aid > 0 else { return }
        Task { @MainActor in
            await appState?.setBroadcast(ownerId: oid, audioId: aid)
        }
    }

    @objc private func onQuickHeart() {
        Task { @MainActor in
            guard let peerId = appState?.selectedPeerId else { return }
            await appState?.sendMessage(peerId: peerId, text: "❤️")
        }
    }

    @objc private func onQuickThumb() {
        Task { @MainActor in
            guard let peerId = appState?.selectedPeerId else { return }
            await appState?.sendMessage(peerId: peerId, text: "👍")
        }
    }

    @objc private func onQuickLaugh() {
        Task { @MainActor in
            guard let peerId = appState?.selectedPeerId else { return }
            await appState?.sendMessage(peerId: peerId, text: "😂")
        }
    }

    @objc private func onStealth() {
        Task { @MainActor in
            guard let appState else { return }
            appState.stealthMode.toggle()
            appState.savePref(key: "stealthMode", value: appState.stealthMode ? "1" : "0")
            refresh()
        }
    }

    @objc private func onLock() {
        Task { @MainActor in
            appState?.isLocked = true
        }
    }
}

private final class TouchBarTrackView: NSView {
    private let onTap: () -> Void
    private let onHold: () -> Void
    private var holdTimer: Timer?
    private var didHold = false

    init(title: String, onTap: @escaping () -> Void, onHold: @escaping () -> Void) {
        self.onTap = onTap
        self.onHold = onHold
        super.init(frame: .zero)

        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.23, alpha: 1.0).cgColor
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: 175),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(with event: NSEvent) {
        didHold = false
        layer?.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.didHold = true
            self.layer?.backgroundColor = NSColor(white: 0.23, alpha: 1.0).cgColor
            self.onHold()
        }
    }

    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        layer?.backgroundColor = NSColor(white: 0.23, alpha: 1.0).cgColor
        if !didHold {
            onTap()
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        layer?.backgroundColor = NSColor(white: 0.23, alpha: 1.0).cgColor
    }
}

private final class TouchBarScrubberView: NSView {
    private var currentTime: Double
    private var duration: Double
    private let onSeek: (Double) -> Void

    init(currentTime: Double, duration: Double, onSeek: @escaping (Double) -> Void) {
        self.currentTime = currentTime
        self.duration = max(duration, 1)
        self.onSeek = onSeek
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1.0).cgColor
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: 370)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(currentTime: Double, duration: Double) {
        self.currentTime = currentTime
        self.duration = max(duration, 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let w = bounds.width
        let h = bounds.height
        let leftPad: CGFloat = 44
        let rightPad: CGFloat = 44
        let trackStart = leftPad
        let trackWidth = max(40, w - leftPad - rightPad)

        let progress = max(0.0, min(1.0, currentTime / max(duration, 1)))
        let cursorX = trackStart + CGFloat(progress) * (trackWidth - 4) + 2

        let step: CGFloat = 3.5
        var x: CGFloat = trackStart + 1
        while x < trackStart + trackWidth - 1 {
            let color: NSColor = x <= cursorX
                ? NSColor.controlAccentColor.withAlphaComponent(0.95)
                : NSColor(white: 0.34, alpha: 0.85)
            color.setFill()
            NSRect(x: x, y: 5, width: 1.3, height: h - 10).fill()
            x += step
        }

        NSColor.white.setFill()
        let cursorRect = NSRect(x: cursorX - 1.5, y: 2, width: 3.0, height: h - 4)
        NSBezierPath(roundedRect: cursorRect, xRadius: 1.5, yRadius: 1.5).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 0.95)
        ]
        let leftStr = NSAttributedString(string: Self.fmt(currentTime), attributes: attrs)
        let leftSize = leftStr.size()
        leftStr.draw(at: NSPoint(x: 6, y: (h - leftSize.height) / 2))

        let rightStr = NSAttributedString(string: Self.fmt(duration), attributes: attrs)
        let rightSize = rightStr.size()
        rightStr.draw(at: NSPoint(x: w - rightSize.width - 6, y: (h - rightSize.height) / 2))
    }

    private static func fmt(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    override func touchesBegan(with event: NSEvent) {
        handleTouch(event)
    }

    override func touchesMoved(with event: NSEvent) {
        handleTouch(event)
    }

    private func handleTouch(_ event: NSEvent) {
        guard let touch = event.touches(matching: .touching, in: self).first else { return }
        let loc = touch.location(in: self)
        let leftPad: CGFloat = 44
        let rightPad: CGFloat = 44
        let trackWidth = max(40, bounds.width - leftPad - rightPad)
        let frac = max(0.0, min(1.0, Double((loc.x - leftPad) / trackWidth)))
        let targetSecs = frac * duration
        currentTime = targetSecs
        needsDisplay = true
        onSeek(targetSecs)
    }
}

private final class TouchBarVolumeView: NSView {
    private var volume: Float
    private let onChange: (Float) -> Void

    init(volume: Float, onChange: @escaping (Float) -> Void) {
        self.volume = max(0, min(1, volume))
        self.onChange = onChange
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1.0).cgColor
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: 125)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let h = bounds.height
        let iconName = volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let tinted = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                NSColor.white.withAlphaComponent(0.9).set()
                img.draw(in: rect)
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 8, y: (h - 14) / 2, width: 14, height: 14))
        }

        let barX: CGFloat = 28
        let barW = bounds.width - barX - 10
        let barH: CGFloat = 6
        let barY = (h - barH) / 2

        NSColor(white: 0.32, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH), xRadius: 3, yRadius: 3).fill()

        let fillW = max(0, barW * CGFloat(volume))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: fillW, height: barH), xRadius: 3, yRadius: 3).fill()

        let knobX = barX + fillW - 6
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: max(barX - 4, min(barX + barW - 8, knobX)), y: (h - 12) / 2, width: 12, height: 12)).fill()
    }

    override func touchesBegan(with event: NSEvent) {
        handleTouch(event)
    }

    override func touchesMoved(with event: NSEvent) {
        handleTouch(event)
    }

    private func handleTouch(_ event: NSEvent) {
        guard let touch = event.touches(matching: .touching, in: self).first else { return }
        let loc = touch.location(in: self)
        let barX: CGFloat = 28
        let barW = max(20, bounds.width - barX - 10)
        let v = Float(max(0, min(1, (loc.x - barX) / barW)))
        volume = v
        needsDisplay = true
        onChange(v)
    }
}
