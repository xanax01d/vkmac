import Foundation

// MARK: - Encodable JSON Helpers & DTOs (Swift 5.8.1 / UniFFI 0.28.3)

private struct Nullable<T: Encodable>: Encodable {
    let value: T?
    init(_ value: T?) {
        self.value = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value {
            try container.encode(v)
        } else {
            try container.encodeNil()
        }
    }
}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        self._encode = { try value.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

private struct AuthStateDTO: Encodable {
    let state: String
    let validationType: Nullable<String>
    let phoneMask: Nullable<String>
    let sid: Nullable<String>
    let imgUrl: Nullable<String>
    let userId: Nullable<Int64>

    enum CodingKeys: String, CodingKey {
        case state
        case validationType = "validation_type"
        case phoneMask = "phone_mask"
        case sid
        case imgUrl = "img_url"
        case userId = "user_id"
    }

    init(_ raw: AuthState) {
        switch raw {
        case .loggedOut:
            self.state = "LoggedOut"
            self.validationType = Nullable(nil)
            self.phoneMask = Nullable(nil)
            self.sid = Nullable(nil)
            self.imgUrl = Nullable(nil)
            self.userId = Nullable(nil)
        case .needs2Fa(let validationType, let phoneMask):
            self.state = "Needs2FA"
            self.validationType = Nullable(validationType)
            self.phoneMask = Nullable(phoneMask)
            self.sid = Nullable(nil)
            self.imgUrl = Nullable(nil)
            self.userId = Nullable(nil)
        case .needsCaptcha(let sid, let imgUrl):
            self.state = "NeedsCaptcha"
            self.validationType = Nullable(nil)
            self.phoneMask = Nullable(nil)
            self.sid = Nullable(sid)
            self.imgUrl = Nullable(imgUrl)
            self.userId = Nullable(nil)
        case .authenticated(let userId):
            self.state = "Authenticated"
            self.validationType = Nullable(nil)
            self.phoneMask = Nullable(nil)
            self.sid = Nullable(nil)
            self.imgUrl = Nullable(nil)
            self.userId = Nullable(userId)
        }
    }
}

private struct OAuthConfigDTO: Encodable {
    let clientId: String
    let clientSecret: String
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
    init(_ raw: OAuthConfig) {
        self.clientId = raw.clientId
        self.clientSecret = raw.clientSecret
    }
}

private struct UserProfileDTO: Encodable {
    let id: Int64
    let firstName: String
    let lastName: String
    let avatarUrl: Nullable<String>
    let online: Bool
    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case avatarUrl = "avatar_url"
        case online
    }
    init(_ raw: UserProfile) {
        self.id = raw.id
        self.firstName = raw.firstName
        self.lastName = raw.lastName
        self.avatarUrl = Nullable(raw.avatarUrl)
        self.online = raw.online
    }
}

private struct ConversationItemDTO: Encodable {
    let peerId: Int64
    let title: String
    let avatarUrl: Nullable<String>
    let lastMessageText: String
    let lastMessageDate: Int64
    let unreadCount: UInt32
    let isMuted: Bool
    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case title
        case avatarUrl = "avatar_url"
        case lastMessageText = "last_message_text"
        case lastMessageDate = "last_message_date"
        case unreadCount = "unread_count"
        case isMuted = "is_muted"
    }
    init(_ raw: ConversationItem) {
        self.peerId = raw.peerId
        self.title = raw.title
        self.avatarUrl = Nullable(raw.avatarUrl)
        self.lastMessageText = raw.lastMessageText
        self.lastMessageDate = raw.lastMessageDate
        self.unreadCount = raw.unreadCount
        self.isMuted = raw.isMuted
    }
}

private struct AttachmentDTO: Encodable {
    let type: String
    let url: Nullable<String>
    let width: Nullable<UInt32>
    let height: Nullable<UInt32>
    let artist: Nullable<String>
    let title: Nullable<String>
    let durationSec: Nullable<UInt32>
    let ext: Nullable<String>
    let kind: Nullable<String>

    enum CodingKeys: String, CodingKey {
        case type
        case url
        case width
        case height
        case artist
        case title
        case durationSec = "duration_sec"
        case ext
        case kind
    }

    init(_ raw: Attachment) {
        switch raw {
        case .photo(let url, let width, let height):
            self.type = "Photo"
            self.url = Nullable(url)
            self.width = Nullable(width)
            self.height = Nullable(height)
            self.artist = Nullable(nil)
            self.title = Nullable(nil)
            self.durationSec = Nullable(nil)
            self.ext = Nullable(nil)
            self.kind = Nullable(nil)
        case .audio(let artist, let title, let durationSec, let url):
            self.type = "Audio"
            self.url = Nullable(url)
            self.width = Nullable(nil)
            self.height = Nullable(nil)
            self.artist = Nullable(artist)
            self.title = Nullable(title)
            self.durationSec = Nullable(durationSec)
            self.ext = Nullable(nil)
            self.kind = Nullable(nil)
        case .document(let title, let url, let ext):
            self.type = "Document"
            self.url = Nullable(url)
            self.width = Nullable(nil)
            self.height = Nullable(nil)
            self.artist = Nullable(nil)
            self.title = Nullable(title)
            self.durationSec = Nullable(nil)
            self.ext = Nullable(ext)
            self.kind = Nullable(nil)
        case .sticker(let url):
            self.type = "Sticker"
            self.url = Nullable(url)
            self.width = Nullable(nil)
            self.height = Nullable(nil)
            self.artist = Nullable(nil)
            self.title = Nullable(nil)
            self.durationSec = Nullable(nil)
            self.ext = Nullable(nil)
            self.kind = Nullable(nil)
        case .link(let title, let url):
            self.type = "Link"
            self.url = Nullable(url)
            self.width = Nullable(nil)
            self.height = Nullable(nil)
            self.artist = Nullable(nil)
            self.title = Nullable(title)
            self.durationSec = Nullable(nil)
            self.ext = Nullable(nil)
            self.kind = Nullable(nil)
        case .unknown(let kind):
            self.type = "Unknown"
            self.url = Nullable(nil)
            self.width = Nullable(nil)
            self.height = Nullable(nil)
            self.artist = Nullable(nil)
            self.title = Nullable(nil)
            self.durationSec = Nullable(nil)
            self.ext = Nullable(nil)
            self.kind = Nullable(kind)
        }
    }
}

private struct MessageItemDTO: Encodable {
    let id: Int64
    let peerId: Int64
    let fromId: Int64
    let text: String
    let date: Int64
    let isOut: Bool
    let attachments: [AttachmentDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case peerId = "peer_id"
        case fromId = "from_id"
        case text
        case date
        case isOut = "is_out"
        case attachments
    }

    init(_ raw: MessageItem) {
        self.id = raw.id
        self.peerId = raw.peerId
        self.fromId = raw.fromId
        self.text = raw.text
        self.date = raw.date
        self.isOut = raw.isOut
        self.attachments = raw.attachments.map { AttachmentDTO($0) }
    }
}

private struct FeedPostDTO: Encodable {
    let postId: Int64
    let sourceId: Int64
    let authorName: String
    let authorAvatar: Nullable<String>
    let date: Int64
    let text: String
    let photos: [String]
    let likesCount: UInt32
    let isLiked: Bool
    let commentsCount: UInt32

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case sourceId = "source_id"
        case authorName = "author_name"
        case authorAvatar = "author_avatar"
        case date
        case text
        case photos
        case likesCount = "likes_count"
        case isLiked = "is_liked"
        case commentsCount = "comments_count"
    }

    init(_ raw: FeedPost) {
        self.postId = raw.postId
        self.sourceId = raw.sourceId
        self.authorName = raw.authorName
        self.authorAvatar = Nullable(raw.authorAvatar)
        self.date = raw.date
        self.text = raw.text
        self.photos = raw.photos
        self.likesCount = raw.likesCount
        self.isLiked = raw.isLiked
        self.commentsCount = raw.commentsCount
    }
}

private struct NewsfeedPageDTO: Encodable {
    let items: [FeedPostDTO]
    let nextFrom: Nullable<String>

    enum CodingKeys: String, CodingKey {
        case items
        case nextFrom = "next_from"
    }

    init(_ raw: NewsfeedPage) {
        self.items = raw.items.map { FeedPostDTO($0) }
        self.nextFrom = Nullable(raw.nextFrom)
    }
}

private struct AudioTrackDTO: Encodable {
    let id: Int64
    let ownerId: Int64
    let artist: String
    let title: String
    let durationSec: UInt32
    let streamUrl: Nullable<String>
    let coverUrl: Nullable<String>

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case artist
        case title
        case durationSec = "duration_sec"
        case streamUrl = "stream_url"
        case coverUrl = "cover_url"
    }

    init(_ raw: AudioTrack) {
        self.id = raw.id
        self.ownerId = raw.ownerId
        self.artist = raw.artist
        self.title = raw.title
        self.durationSec = raw.durationSec
        self.streamUrl = Nullable(raw.streamUrl)
        self.coverUrl = Nullable(raw.coverUrl)
    }
}

private struct VkEventDTO: Encodable {
    let type: String
    let message: Nullable<MessageItemDTO>
    let peerId: Nullable<Int64>
    let msgId: Nullable<Int64>
    let userId: Nullable<Int64>
    let connected: Nullable<Bool>

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case peerId = "peer_id"
        case msgId = "msg_id"
        case userId = "user_id"
        case connected
    }

    init(_ raw: VkEvent) {
        switch raw {
        case .newMessage(let message):
            self.type = "NewMessage"
            self.message = Nullable(MessageItemDTO(message))
            self.peerId = Nullable(nil)
            self.msgId = Nullable(nil)
            self.userId = Nullable(nil)
            self.connected = Nullable(nil)
        case .messageEdited(let message):
            self.type = "MessageEdited"
            self.message = Nullable(MessageItemDTO(message))
            self.peerId = Nullable(nil)
            self.msgId = Nullable(nil)
            self.userId = Nullable(nil)
            self.connected = Nullable(nil)
        case .readIncoming(let peerId, let msgId):
            self.type = "ReadIncoming"
            self.message = Nullable(nil)
            self.peerId = Nullable(peerId)
            self.msgId = Nullable(msgId)
            self.userId = Nullable(nil)
            self.connected = Nullable(nil)
        case .readOutgoing(let peerId, let msgId):
            self.type = "ReadOutgoing"
            self.message = Nullable(nil)
            self.peerId = Nullable(peerId)
            self.msgId = Nullable(msgId)
            self.userId = Nullable(nil)
            self.connected = Nullable(nil)
        case .typing(let peerId, let userId):
            self.type = "Typing"
            self.message = Nullable(nil)
            self.peerId = Nullable(peerId)
            self.msgId = Nullable(nil)
            self.userId = Nullable(userId)
            self.connected = Nullable(nil)
        case .connectionStatus(let connected):
            self.type = "ConnectionStatus"
            self.message = Nullable(nil)
            self.peerId = Nullable(nil)
            self.msgId = Nullable(nil)
            self.userId = Nullable(nil)
            self.connected = Nullable(connected)
        }
    }
}

private struct ErrorResponseDTO: Encodable {
    let ok: Bool = false
    let op: Nullable<String>
    let errorKind: String
    let message: String
    let code: Nullable<Int32>
    let validationType: Nullable<String>
    let phoneMask: Nullable<String>
    let sid: Nullable<String>
    let imgUrl: Nullable<String>
    let details: Nullable<String>

    enum CodingKeys: String, CodingKey {
        case ok
        case op
        case errorKind = "error_kind"
        case message
        case code
        case validationType = "validation_type"
        case phoneMask = "phone_mask"
        case sid
        case imgUrl = "img_url"
        case details
    }

    static func fromVkError(_ err: VkError, op: String?) -> ErrorResponseDTO {
        switch err {
        case .InvalidToken:
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "InvalidToken",
                message: err.localizedDescription,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(nil)
            )
        case .ValidationRequired(let validationType, let phoneMask):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "ValidationRequired",
                message: err.localizedDescription,
                code: Nullable(nil),
                validationType: Nullable(validationType),
                phoneMask: Nullable(phoneMask),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(nil)
            )
        case .CaptchaRequired(let sid, let imgUrl):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "CaptchaRequired",
                message: err.localizedDescription,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(sid),
                imgUrl: Nullable(imgUrl),
                details: Nullable(nil)
            )
        case .ApiError(let code, let message):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "ApiError",
                message: message,
                code: Nullable(code),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(message)
            )
        case .Network(let details):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "Network",
                message: details,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(details)
            )
        case .Storage(let details):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "Storage",
                message: details,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(details)
            )
        case .Keychain(let details):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "Keychain",
                message: details,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(details)
            )
        case .InvalidInput(let details):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "InvalidInput",
                message: details,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(details)
            )
        case .RateLimited:
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "RateLimited",
                message: err.localizedDescription,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(nil)
            )
        case .Internal(let details):
            return ErrorResponseDTO(
                op: Nullable(op),
                errorKind: "Internal",
                message: details,
                code: Nullable(nil),
                validationType: Nullable(nil),
                phoneMask: Nullable(nil),
                sid: Nullable(nil),
                imgUrl: Nullable(nil),
                details: Nullable(details)
            )
        }
    }
}

private struct SuccessResponseDTO: Encodable {
    let ok: Bool = true
    let op: String
    let result: AnyEncodable
    let events: [VkEventDTO]
}

private struct BatchStepDTO: Encodable {
    let op: String
    let result: AnyEncodable
}

private struct BatchResponseDTO: Encodable {
    let ok: Bool = true
    let results: [BatchStepDTO]
    let events: [VkEventDTO]
}

// MARK: - Thread-safe VkEventListener

private final class EventCollector: VkEventListener {
    private let lock = NSLock()
    private var collected: [VkEvent] = []

    func onEvent(event: VkEvent) {
        lock.lock()
        collected.append(event)
        lock.unlock()
    }

    func snapshot() -> [VkEvent] {
        lock.lock()
        let copy = collected
        lock.unlock()
        return copy
    }

    func count() -> Int {
        lock.lock()
        let c = collected.count
        lock.unlock()
        return c
    }
}

// MARK: - Parameter Extractors

private func strOpt(_ dict: [String: Any], _ key: String) -> String? {
    if let s = dict[key] as? String {
        return s
    }
    return nil
}

private func strReq(_ dict: [String: Any], _ key: String, default def: String = "") -> String {
    return (dict[key] as? String) ?? def
}

private struct HarnessInputError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

private func int64Param(_ dict: [String: Any], _ key: String, default def: Int64 = 0) throws -> Int64 {
    guard let raw = dict[key], !(raw is NSNull) else {
        return def
    }
    if let n = raw as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            throw HarnessInputError("Parameter '\(key)' must be an integer, got boolean")
        }
        if CFNumberIsFloatType(n) {
            throw HarnessInputError("Parameter '\(key)' must be an integer, got floating-point number")
        }
        if String(cString: n.objCType) == "Q" {
            let u = n.uint64Value
            if u > UInt64(Int64.max) {
                throw HarnessInputError("Parameter '\(key)' exceeds Int64.max")
            }
            return Int64(u)
        }
        return n.int64Value
    }
    if let s = raw as? String {
        guard let v = Int64(s) else {
            throw HarnessInputError("Parameter '\(key)' must be a valid Int64 string, got '\(s)'")
        }
        return v
    }
    throw HarnessInputError("Parameter '\(key)' must be an Int64")
}

private func uint32Param(_ dict: [String: Any], _ key: String, default def: UInt32 = 0) throws -> UInt32 {
    guard let raw = dict[key], !(raw is NSNull) else {
        return def
    }
    if let n = raw as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            throw HarnessInputError("Parameter '\(key)' must be a non-negative UInt32, got boolean")
        }
        if CFNumberIsFloatType(n) {
            throw HarnessInputError("Parameter '\(key)' must be a non-negative UInt32, got floating-point number")
        }
        if String(cString: n.objCType) == "Q" {
            let u = n.uint64Value
            guard u <= UInt64(UInt32.max), let exact = UInt32(exactly: u) else {
                throw HarnessInputError("Parameter '\(key)' out of UInt32 range [0, \(UInt32.max)]")
            }
            return exact
        }
        let v = n.int64Value
        guard v >= 0, v <= Int64(UInt32.max), let exact = UInt32(exactly: v) else {
            throw HarnessInputError("Parameter '\(key)' out of UInt32 range [0, \(UInt32.max)], got \(v)")
        }
        return exact
    }
    if let s = raw as? String {
        guard let v = UInt32(s) else {
            throw HarnessInputError("Parameter '\(key)' must be a valid UInt32 string, got '\(s)'")
        }
        return v
    }
    throw HarnessInputError("Parameter '\(key)' must be a UInt32")
}

// MARK: - Output Helpers

private func emitJSON<T: Encodable>(_ value: T, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"ok\":false,\"error_kind\":\"HarnessError\",\"message\":\"UTF-8 encode failed\"}")
        }
    } catch {
        print("{\"ok\":false,\"error_kind\":\"HarnessError\",\"message\":\"JSON encode error: \(error)\"}")
    }
    fflush(stdout)
    fflush(stderr)
    exit(exitCode)
}

private func failHarness(_ op: String?, kind: String, message: String, exitCode: Int32 = 1) -> Never {
    let dto = ErrorResponseDTO(
        op: Nullable(op),
        errorKind: kind,
        message: message,
        code: Nullable(nil),
        validationType: Nullable(nil),
        phoneMask: Nullable(nil),
        sid: Nullable(nil),
        imgUrl: Nullable(nil),
        details: Nullable(message)
    )
    emitJSON(dto, exitCode: exitCode)
}

// MARK: - Command Execution

private func executeOp(
    client: VkClient,
    collector: EventCollector,
    op: String,
    params: [String: Any]
) async throws -> AnyEncodable {
    switch op {
    case "restore_session":
        let state = await client.restoreSession()
        return AnyEncodable(AuthStateDTO(state))

    case "login_password":
        let login = strReq(params, "login")
        let password = strReq(params, "password")
        let code2fa = strOpt(params, "code_2fa")
        let captchaSid = strOpt(params, "captcha_sid")
        let captchaKey = strOpt(params, "captcha_key")
        let state = try await client.loginPassword(
            login: login,
            password: password,
            code2fa: code2fa,
            captchaSid: captchaSid,
            captchaKey: captchaKey
        )
        return AnyEncodable(AuthStateDTO(state))

    case "login_with_redirect_url":
        let url = strReq(params, "url")
        let state = try await client.loginWithRedirectUrl(url: url)
        return AnyEncodable(AuthStateDTO(state))

    case "logout":
        try await client.logout()
        return AnyEncodable(true)

    case "subscribe_events":
        await client.subscribeEvents(listener: collector)
        return AnyEncodable(true)

    case "collect_events":
        let waitMs = try uint32Param(params, "wait_ms", default: 500)
        let minEvents = Int(try uint32Param(params, "min_events", default: 0))
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)
        while Date() < deadline {
            if minEvents > 0 && collector.count() >= minEvents {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return AnyEncodable(collector.snapshot().map { VkEventDTO($0) })

    case "get_oauth_config":
        let cfg = client.getOauthConfig()
        return AnyEncodable(OAuthConfigDTO(cfg))

    case "set_oauth_config":
        let clientId = strReq(params, "client_id")
        let clientSecret = strReq(params, "client_secret")
        try client.setOauthConfig(clientId: clientId, clientSecret: clientSecret)
        return AnyEncodable(true)

    case "get_oauth_authorize_url":
        let url = client.getOauthAuthorizeUrl()
        return AnyEncodable(url)

    case "get_current_user":
        let profile = try await client.getCurrentUser()
        return AnyEncodable(Nullable(profile.map { UserProfileDTO($0) }))

    case "get_cached_conversations":
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 20)
        let items = try client.getCachedConversations(offset: offset, count: count)
        return AnyEncodable(items.map { ConversationItemDTO($0) })

    case "get_conversations":
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 20)
        let items = try await client.getConversations(offset: offset, count: count)
        return AnyEncodable(items.map { ConversationItemDTO($0) })

    case "get_cached_messages":
        let peerId = try int64Param(params, "peer_id")
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 50)
        let items = try client.getCachedMessages(peerId: peerId, offset: offset, count: count)
        return AnyEncodable(items.map { MessageItemDTO($0) })

    case "get_messages":
        let peerId = try int64Param(params, "peer_id")
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 50)
        let items = try await client.getMessages(peerId: peerId, offset: offset, count: count)
        return AnyEncodable(items.map { MessageItemDTO($0) })

    case "send_message":
        let peerId = try int64Param(params, "peer_id")
        let text = strReq(params, "text")
        let item = try await client.sendMessage(peerId: peerId, text: text)
        return AnyEncodable(MessageItemDTO(item))

    case "get_newsfeed":
        let startFrom = strOpt(params, "start_from")
        let page = try await client.getNewsfeed(startFrom: startFrom)
        return AnyEncodable(NewsfeedPageDTO(page))

    case "like_post":
        let ownerId = try int64Param(params, "owner_id")
        let postId = try int64Param(params, "post_id")
        let count = try await client.likePost(ownerId: ownerId, postId: postId)
        return AnyEncodable(count)

    case "unlike_post":
        let ownerId = try int64Param(params, "owner_id")
        let postId = try int64Param(params, "post_id")
        let count = try await client.unlikePost(ownerId: ownerId, postId: postId)
        return AnyEncodable(count)

    case "get_cached_audio":
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 50)
        let tracks = try client.getCachedAudio(offset: offset, count: count)
        return AnyEncodable(tracks.map { AudioTrackDTO($0) })

    case "get_audio":
        let offset = try uint32Param(params, "offset", default: 0)
        let count = try uint32Param(params, "count", default: 50)
        let tracks = try await client.getAudio(offset: offset, count: count)
        return AnyEncodable(tracks.map { AudioTrackDTO($0) })

    case "search_audio":
        let query = strReq(params, "query")
        let tracks = try await client.searchAudio(query: query)
        return AnyEncodable(tracks.map { AudioTrackDTO($0) })

    case "clear_cache":
        try client.clearCache()
        return AnyEncodable(true)

    case "get_cache_size_bytes":
        let size = try client.getCacheSizeBytes()
        return AnyEncodable(size)

    default:
        throw VkError.InvalidInput(details: "Unknown harness operation: \(op)")
    }
}

@main
struct VkE2eHarness {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            let help = """
            vk_e2e_harness — Opaque-box Swift UniFFI CLI harness for VkClient

            Usage:
              vk_e2e_harness --input <payload.json>
              echo '<json>' | vk_e2e_harness
              vk_e2e_harness --help

            Input JSON:
              {"data_dir": "/path/to/data", "op": "<method>", "params": {...}}
              {"data_dir": "/path/to/data", "ops": [{"op": "<method>", "params": {...}}, ...]}
            """
            print(help)
            fflush(stdout)
            exit(0)
        }

        var inputPath: String? = nil
        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            if arg == "--input" && idx + 1 < args.count {
                inputPath = args[idx + 1]
                idx += 2
            } else {
                failHarness(nil, kind: "HarnessInputError", message: "Unknown argument: \(arg)", exitCode: 2)
            }
        }

        let inputData: Data
        if let path = inputPath {
            do {
                inputData = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                failHarness(nil, kind: "HarnessInputError", message: "Failed to read --input \(path): \(error)", exitCode: 2)
            }
        } else {
            inputData = FileHandle.standardInput.readDataToEndOfFile()
        }

        guard !inputData.isEmpty else {
            failHarness(nil, kind: "HarnessInputError", message: "Empty JSON input", exitCode: 2)
        }

        let parsedAny: Any
        do {
            parsedAny = try JSONSerialization.jsonObject(with: inputData, options: [])
        } catch {
            failHarness(nil, kind: "HarnessInputError", message: "Invalid JSON input: \(error)", exitCode: 2)
        }

        guard let payload = parsedAny as? [String: Any] else {
            failHarness(nil, kind: "HarnessInputError", message: "JSON root must be an object", exitCode: 2)
        }

        let dataDir = (payload["data_dir"] as? String) ?? ""
        let collector = EventCollector()

        let client: VkClient
        do {
            client = try VkClient(dataDir: dataDir)
        } catch let vkErr as VkError {
            emitJSON(ErrorResponseDTO.fromVkError(vkErr, op: "init"), exitCode: 1)
        } catch {
            failHarness("init", kind: "UnexpectedError", message: "\(error)", exitCode: 1)
        }

        if let opsList = payload["ops"] as? [[String: Any]] {
            var results: [BatchStepDTO] = []
            for step in opsList {
                guard let stepOp = step["op"] as? String else {
                    failHarness(nil, kind: "HarnessInputError", message: "Each entry in ops must have string 'op'", exitCode: 2)
                }
                let stepParams = (step["params"] as? [String: Any]) ?? [:]
                do {
                    let res = try await executeOp(client: client, collector: collector, op: stepOp, params: stepParams)
                    results.append(BatchStepDTO(op: stepOp, result: res))
                } catch let inputErr as HarnessInputError {
                    failHarness(stepOp, kind: "HarnessInputError", message: inputErr.message, exitCode: 2)
                } catch let vkErr as VkError {
                    emitJSON(ErrorResponseDTO.fromVkError(vkErr, op: stepOp), exitCode: 1)
                } catch {
                    failHarness(stepOp, kind: "UnexpectedError", message: "\(error)", exitCode: 1)
                }
            }
            let eventDTOs = collector.snapshot().map { VkEventDTO($0) }
            emitJSON(BatchResponseDTO(results: results, events: eventDTOs), exitCode: 0)
        } else if let singleOp = payload["op"] as? String {
            let params = (payload["params"] as? [String: Any]) ?? [:]
            do {
                let res = try await executeOp(client: client, collector: collector, op: singleOp, params: params)
                let eventDTOs = collector.snapshot().map { VkEventDTO($0) }
                emitJSON(SuccessResponseDTO(op: singleOp, result: res, events: eventDTOs), exitCode: 0)
            } catch let inputErr as HarnessInputError {
                failHarness(singleOp, kind: "HarnessInputError", message: inputErr.message, exitCode: 2)
            } catch let vkErr as VkError {
                emitJSON(ErrorResponseDTO.fromVkError(vkErr, op: singleOp), exitCode: 1)
            } catch {
                failHarness(singleOp, kind: "UnexpectedError", message: "\(error)", exitCode: 1)
            }
        } else {
            failHarness(nil, kind: "HarnessInputError", message: "Payload must contain 'op' or 'ops'", exitCode: 2)
        }
    }
}
