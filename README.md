<div align="center">

# VKMac

**Нативный клиент ВКонтакте для macOS на Rust + SwiftUI**

![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![Platform](https://img.shields.io/badge/macOS-13.0%2B-black.svg?logo=apple)
![Core](https://img.shields.io/badge/core-Rust%20%2B%20UniFFI-orange.svg?logo=rust)
![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF.svg?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green.svg)

Быстрый, лёгкий и автономный клиент ВКонтакте без Electron и Web-обёрток: сетевой слой, Long Poll, SQLite-кэш и Keychain реализованы в `vk-core` на **Rust**, а интерфейс — на **SwiftUI / AppKit** через **UniFFI**.

</div>

---

## Возможности

### Мессенджер и боты
- **Мгновенный старт и Long Poll:** диалоги и история кэшируются в SQLite (WAL), новые сообщения, прочтение и статус «печатает...» приходят в реальном времени.
- **Клавиатуры ботов:** поддержка `inline`-клавиатур прямо под сообщениями и нижних клавиатур диалога (`current_keyboard`) под полем ввода, с цветами кнопок, `one_time`, ссылками и `payload`.
- **Медиа и ввод:** вставка изображений по `⌘V` прямо при наборе текста, Drag & Drop файлов, стикеры, шаблоны быстрых ответов, голосовые сообщения с выбором скорости (`1x` / `1.5x` / `2x`).
- **Навигация и приватность:** папки («Все», «Непроч.», «Личные», «Беседы», «Группы», «Архив»), закреплённые сообщения, цитаты ответов и пересланных сообщений, статистика переписки, режим **«Тихое чтение»**, быстрый ответ из уведомлений macOS и отдельные поп-аут окна с **Always-on-Top**.

### Лента, закладки и профили
- **Лента новостей:** посты, репосты (`copy_history`), опросы, видео, документы, ссылки, лайки, репосты в чат, скрытие постов и детальный экран поста с комментариями.
- **Закладки:** отдельные вкладки для постов, ссылок и страниц.
- **Профили и сообщества:** страницы пользователей и групп, редактирование своего статуса, входящие/исходящие заявки в друзья, чёрный список и мониторинг стен.
- **Просмотр медиа в окне:** встроенный оверлей для фото и видео внутри основного окна — переключение `←` / `→`, зум, комментарии к видео, сохранение на диск и закрытие по `Esc`.

### Музыка и интеграция с macOS
- **Аудиоплеер:** стриминг HLS (`.m3u8`) через `AVPlayer`, плейлисты, добавление в плейлисты, «Волна» по треку (`audio.getRecommendations`), тексты песен, пресеты EQ.
- **Система:** `MPNowPlayingInfoCenter`, медиа-клавиши и AirPods, **автопауза при отключении наушников** (`CoreAudio`).
- **Touch Bar:** переключение разделов, свайпаемая контекстная панель, скраббер прогресса трека и поповер управления.
- **macOS-фичи:** мультиаккаунтность (одна запись в Keychain), блокировка по Touch ID, меню Dock, глубокие ссылки `vk://`, режимы интерфейса (Полный / Мессенджер / Музыка) и кастомный акцентный цвет.

---

## Горячие клавиши

| Сочетание | Действие |
| :--- | :--- |
| `⌥ Space` | Глобально показать / скрыть окно VKMac |
| `⌘ K` | Открыть палитру команд |
| `⌘ L` | Заблокировать приложение (Touch ID) |
| `⌘ 1` – `⌘ 9` | Быстрое переключение вкладок |
| `⌘ V` | Вставить изображение из буфера обмена в чат |
| `←` / `→` / `Esc` | Навигация и закрытие в просмотре фото/видео |

---

## Архитектура

```text
┌───────────────────────────────────────────────────────────┐
│                    VKMac (SwiftUI / AppKit)               │
│  MainSplitView · ChatsView · FeedView · MusicView ·       │
│  TouchBarController · PhotoViewerView · PopoutChatWindow  │
└─────────────────────────────┬─────────────────────────────┘
                              │ UniFFI (C FFI + Swift bindings)
┌─────────────────────────────▼─────────────────────────────┐
│                       vk-core (Rust)                      │
│  VkApiClient (reqwest) · LongPollWorker (tokio) ·         │
│  Storage (SQLite WAL) · KeychainStore (Security.framework)│
└───────────────────────────────────────────────────────────┘
```

### Структура проекта

```text
vk-mac/
├── vk-core/              # Ядро на Rust (API, Long Poll, SQLite, Keychain, модели)
├── uniffi-bindgen/       # Генератор Swift-биндингов UniFFI
├── VKMac/
│   ├── Sources/VKMac/    # SwiftUI-интерфейс, AppState, AudioPlayerService, TouchBar
│   ├── Generated/        # Сгенерированные UniFFI Swift/C файлы
│   └── Resources/        # Иконка приложения и ресурсы бандла
├── scripts/
│   └── build_app.sh      # Сборка release, UniFFI, упаковка и подпись VKMac.app
└── Cargo.toml
```

---

## Сборка, тесты и установка

Требования: **macOS 13+**, `rustc` / `cargo`, Command Line Tools for Xcode (`swiftc`). Полный `Xcode.app` не обязателен.

```bash
# 1. Запуск unit- и интеграционных тестов Rust-ядра
cargo test --workspace

# 2. Сборка vk-core (release), генерация UniFFI-биндингов и упаковка build/VKMac.app
./scripts/build_app.sh

# 3. Установка в /Applications (опционально)
rm -rf /Applications/VKMac.app && cp -R build/VKMac.app /Applications/VKMac.app

# 4. Запуск
open build/VKMac.app
```

---

## Хранение данных и безопасность

- **Токены и мультиаккаунты:** хранятся в одной записи **macOS Keychain** (`com.vkmac.client` / `session`) с кэшированием в памяти — Keychain запрашивается **только 1 раз** при старте.
- **Локальный кэш:** `~/Library/Application Support/VKMac/cache.db` (SQLite, режим WAL).
- **Лицензия:** [MIT](LICENSE)
