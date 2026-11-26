import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var savedBanner: Bool = false

    var body: some View {
        Form {
            Section("Аккаунт") {
                if let user = appState.currentUser {
                    HStack(spacing: 12) {
                        if let avatar = user.avatarUrl, let url = URL(string: avatar) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.2)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(user.firstName) \(user.lastName)")
                                .font(.headline)
                            Text("ID: \(user.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Выйти из аккаунта", role: .destructive) {
                    Task {
                        await appState.logout()
                    }
                }
            }

            Section("Мультиаккаунт") {
                ForEach(appState.savedAccounts, id: \.userId) { acc in
                    HStack {
                        AvatarView(urlString: acc.avatarUrl, title: acc.name, size: 26)
                        Text(acc.name)
                        Spacer()
                        if acc.userId == appState.currentUser?.id {
                            Text("Активен")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Button("Переключить") {
                                Task { await appState.switchAccount(acc.userId) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                Button("Добавить другой аккаунт") {
                    appState.addAnotherAccount()
                }
            }

            Section("Чёрный список") {
                Button("Загрузить чёрный список") {
                    Task { await appState.loadBanned() }
                }
                ForEach(appState.bannedUsers, id: \.id) { u in
                    HStack {
                        AvatarView(urlString: u.avatarUrl, title: u.name, size: 24)
                        Text(u.name)
                        Spacer()
                        Button("Разблокировать") {
                            Task { await appState.unbanUser(u.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Section("OAuth-конфигурация клиента") {
                TextField("Client ID", text: $appState.oauthClientId)
                SecureField("Client Secret", text: $appState.oauthClientSecret)
                HStack {
                    Button("Сохранить параметры") {
                        appState.saveOAuthConfig()
                        savedBanner = true
                    }
                    if savedBanner {
                        Text("Сохранено")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Приватность и безопасность") {
                Toggle("Тихое чтение (не отмечать прочитанным)", isOn: $appState.stealthMode)
                    .onChange(of: appState.stealthMode) { val in
                        appState.savePref(key: "stealthMode", value: val ? "1" : "0")
                    }
                Toggle("Блокировка Touch ID / паролем Mac", isOn: $appState.touchIdEnabled)
                    .onChange(of: appState.touchIdEnabled) { val in
                        appState.savePref(key: "touchIdEnabled", value: val ? "1" : "0")
                    }
                Toggle("Блокировать при сворачивании окна", isOn: $appState.autoLockOnMinimize)
                    .onChange(of: appState.autoLockOnMinimize) { val in
                        appState.savePref(key: "autoLockOnMinimize", value: val ? "1" : "0")
                    }
                Toggle("Скрывать текст сообщений в уведомлениях", isOn: $appState.hideNotificationPreview)
                    .onChange(of: appState.hideNotificationPreview) { val in
                        appState.savePref(key: "hideNotificationPreview", value: val ? "1" : "0")
                    }
                Toggle("Тихие часы (Не беспокоить по расписанию)", isOn: $appState.dndEnabled)
                    .onChange(of: appState.dndEnabled) { val in
                        appState.savePref(key: "dndEnabled", value: val ? "1" : "0")
                        appState.updateDockBadge()
                    }
                if appState.dndEnabled {
                    Stepper("Начало: \(appState.dndStartHour):00", value: $appState.dndStartHour, in: 0...23)
                        .onChange(of: appState.dndStartHour) { val in
                            appState.savePref(key: "dndStartHour", value: "\(val)")
                            appState.updateDockBadge()
                        }
                    Stepper("Конец: \(appState.dndEndHour):00", value: $appState.dndEndHour, in: 0...23)
                        .onChange(of: appState.dndEndHour) { val in
                            appState.savePref(key: "dndEndHour", value: "\(val)")
                            appState.updateDockBadge()
                        }
                }
            }

            Section("Внешний вид и режим") {
                Picker("Акцентный цвет", selection: $appState.accentChoice) {
                    Text("Системный").tag("system")
                    Text("Синий").tag("blue")
                    Text("Фиолетовый").tag("purple")
                    Text("Розовый").tag("pink")
                    Text("Оранжевый").tag("orange")
                    Text("Зелёный").tag("green")
                }
                .onChange(of: appState.accentChoice) { val in
                    appState.savePref(key: "accentChoice", value: val)
                }

                Picker("Режим приложения", selection: $appState.appMode) {
                    Text("Всё вместе").tag("all")
                    Text("Только мессенджер").tag("messenger")
                    Text("Только музыка").tag("music")
                }
                .onChange(of: appState.appMode) { val in
                    appState.savePref(key: "appMode", value: val)
                }

                Toggle("Компактный режим", isOn: $appState.compactMode)
                    .onChange(of: appState.compactMode) { val in
                        appState.savePref(key: "compactMode", value: val ? "1" : "0")
                    }

                Picker("Кроссфейд в музыке", selection: $appState.crossfadeSeconds) {
                    Text("Выкл").tag(0.0)
                    Text("2 сек").tag(2.0)
                    Text("4 сек").tag(4.0)
                    Text("6 сек").tag(6.0)
                }
                .onChange(of: appState.crossfadeSeconds) { val in
                    AudioPlayerService.shared.crossfadeSeconds = val
                    appState.savePref(key: "crossfadeSeconds", value: "\(val)")
                }
            }

            Section("Фильтр шума в ленте") {
                Toggle("Скрывать рекламные посты", isOn: $appState.hideAds)
                    .onChange(of: appState.hideAds) { val in
                        appState.savePref(key: "hideAds", value: val ? "1" : "0")
                    }
                TextField("Стоп-слова (через запятую)", text: $appState.mutedKeywords)
                    .onChange(of: appState.mutedKeywords) { val in
                        appState.savePref(key: "mutedKeywords", value: val)
                    }
            }

            Section("Очистка аккаунта") {
                Button("Найти удалённых / заблокированных друзей") {
                    Task { await appState.loadInactiveFriends() }
                }
                if !appState.inactiveFriends.isEmpty {
                    Text("Найдено: \(appState.inactiveFriends.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(appState.inactiveFriends.prefix(15), id: \.id) { friend in
                        Button {
                            appState.openOwnerPage(friend.id)
                        } label: {
                            HStack {
                                AvatarView(urlString: friend.avatarUrl, title: friend.name, size: 22)
                                Text(friend.name)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Локальный кэш (SQLite)") {
                HStack {
                    Text("Размер кэша")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(appState.cacheSizeBytes), countStyle: .file))
                        .foregroundStyle(.secondary)
                }

                Button("Очистить кэш") {
                    appState.clearCache()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
        .onAppear {
            appState.refreshCacheSize()
        }
    }
}
