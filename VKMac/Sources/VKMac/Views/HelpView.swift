import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                helpSection(
                    icon: "person.badge.key",
                    title: "1. Авторизация, мультиаккаунтность и безопасность"
                ) {
                    Text("""
                    • **Способы входа:** логин и пароль (с поддержкой 2FA и капчи) или вставка токена / ссылки `blank.html#access_token=...` во вкладке **«По токену»**.
                    • **macOS Keychain и кэш:** сессии хранятся в одной записи Keychain (`com.vkmac.client`) и кэшируются в памяти — при запуске Keychain запрашивается только один раз.
                    • **Мультиаккаунтность:** в разделе **«Настройки»** можно добавлять несколько аккаунтов и мгновенно переключаться между ними.
                    • **Touch ID / блокировка:** можно включить блокировку приложения по Touch ID или паролю macOS (`⌘L` или кнопка замка на Touch Bar).
                    """)
                }

                helpSection(
                    icon: "bubble.left.and.bubble.right",
                    title: "2. Чаты, боты и Long Poll"
                ) {
                    Text("""
                    • **Мгновенный старт и Long Poll:** диалоги и сообщения кэшируются в SQLite, а новые сообщения, статусы прочтения и набор текста приходят в реальном времени.
                    • **Клавиатуры ботов:** inline-клавиатуры отображаются под сообщениями, а нижние клавиатуры диалогов — под полем ввода (с поддержкой `one_time`, ссылок и `payload`).
                    • **Медиа и ввод:** отправка текста (`Enter`), вставка картинок по `⌘V` прямо при наборе текста, перетаскивание файлов (Drag & Drop), стикеры, шаблоны быстрых ответов и голосовые сообщения с ускорением (`1x` / `1.5x` / `2x`).
                    • **Порядок и приватность:** папки («Все», «Непроч.», «Личные», «Беседы», «Группы», «Архив»), закреплённые сообщения, цитаты ответов и пересланных сообщений, статистика переписки, «Тихое чтение» (сообщения не помечаются прочитанными), быстрый ответ из уведомлений macOS и отдельные поп-аут окна с кнопкой Always-on-Top.
                    """)
                }

                helpSection(
                    icon: "newspaper",
                    title: "3. Лента, закладки, профили и мониторинг"
                ) {
                    Text("""
                    • **Лента и посты:** просмотр записей, репостов, опросов, видео и фото; лайки, репост в чат, скрытие неинтересных постов и полноэкранный просмотр поста с комментариями.
                    • **Закладки:** отдельные вкладки для сохранённых постов, ссылок и страниц.
                    • **Профили, друзья и чёрный список:** просмотр страниц пользователей и сообществ, редактирование своего статуса, входящие/исходящие заявки в друзья, чёрный список в настройках и **мониторинг стены** для отслеживания новых постов.
                    """)
                }

                helpSection(
                    icon: "photo.on.rectangle.angled",
                    title: "4. Встроенный просмотр фото и видео"
                ) {
                    Text("""
                    • Клик по фото или видео открывает встроенный оверлей прямо в текущем окне приложения.
                    • **Управление:** стрелки `←` / `→` для переключения, кнопки `+` / `-` и двойной клик для зума, комментарии к видео, кнопка сохранения на диск и `Esc` для закрытия.
                    """)
                }

                helpSection(
                    icon: "music.note.list",
                    title: "5. Музыка и медиа-интеграция"
                ) {
                    Text("""
                    • **Плеер:** прослушивание аудио и плейлистов через `AVPlayer`, «Волна» (похожие треки), добавление в плейлисты, текст песни и пресеты эквалайзера в мини-плеере.
                    • **macOS:** интеграция с `MPNowPlayingInfoCenter`, медиа-клавишами и AirPods, а также **автопауза при отключении наушников** (CoreAudio).
                    """)
                }

                helpSection(
                    icon: "keyboard",
                    title: "6. Touch Bar, горячие клавиши и macOS"
                ) {
                    Text("""
                    • **Touch Bar:** переключение разделов, контекстные быстрые реакции/действия (прокручиваемая панель), скраббер прогресса трека и поповер управления при воспроизведении.
                    • **Хоткеи:** `⌥Space` — показать/скрыть окно из любого приложения, `⌘K` — палитра команд, `⌘L` — блокировка, `⌘1–⌘9` — быстрое переключение разделов.
                    • **Система:** меню Dock, глубокие ссылки `vk://` и выбор режима интерфейса (полный, мессенджер, музыка) в настройках.
                    """)
                }

                helpSection(
                    icon: "internaldrive",
                    title: "7. Локальный кэш и данные"
                ) {
                    Text("""
                    • База данных SQLite (WAL) хранится в `~/Library/Application Support/VKMac/cache.db`.
                    • В **«Настройках»** можно проверить размер кэша, очистить его, настроить акцентный цвет и управлять аккаунтами.
                    """)
                }
            }
            .padding(24)
        }
        .navigationTitle("Справка")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Справка VKMac")
                        .font(.title.bold())
                    Text("v1.0.0")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Text("Руководство пользователя нативного клиента ВКонтакте для macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func helpSection<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
