import Foundation
import Network
import Security

public struct QQMailboxCredentials: Sendable {
    public let address: String
    public let authorizationCode: String
    public init(address: String, authorizationCode: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.range(of: #"^[a-z0-9._%+\-]+@(?:qq|vip\.qq|foxmail)\.com$"#, options: .regularExpression) != nil else {
            throw QQMailboxError.invalidAddress
        }
        guard !key.isEmpty, key.rangeOfCharacter(from: .controlCharacters) == nil else { throw QQMailboxError.missingCode }
        self.address = address
        self.authorizationCode = key
    }
}

public enum QQMailboxError: LocalizedError {
    case invalidAddress, missingCode, keychain(OSStatus), connection, rejected, malformed, tooLarge, changedMailbox
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请填写有效的 QQ 邮箱地址。"
        case .missingCode: "请填写 QQ 邮箱授权码，授权码不是 QQ 登录密码。"
        case .keychain(let status): "无法访问邮箱授权码（\(status)），请检查钥匙串授权。"
        case .connection: "无法连接 QQ 邮箱，请检查网络后重试。"
        case .rejected: "QQ 邮箱拒绝请求，请检查 IMAP 服务是否开启、授权码是否有效。"
        case .malformed: "邮件格式无法解析，请在 QQ 邮箱中查看并手动导入。"
        case .tooLarge: "邮件内容超过 30 MB，请在 QQ 邮箱中下载后手动导入。"
        case .changedMailbox: "邮箱或邮件编号已变化，请重新同步后下载附件。"
        }
    }
}

@MainActor public enum QQMailboxConfiguration {
    private static let prefix = "reimbursement.qqmail."
    private static let service = "top.kjoe.ReimburseMacApp.qqmail"
    public private(set) static var revision = 0
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: prefix + "enabled") }
    public static var address: String { UserDefaults.standard.string(forKey: prefix + "address") ?? "" }
    public static var since: Date { Calendar.current.startOfDay(for: UserDefaults.standard.object(forKey: prefix + "since") as? Date ?? Date().addingTimeInterval(-30 * 86400)) }

    public static func save(address: String, authorizationCode: String, enabled: Bool, since: Date) throws {
        let account = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled || !account.isEmpty {
            _ = try QQMailboxCredentials(address: account, authorizationCode: code.isEmpty ? "validation" : code)
            if !code.isEmpty {
                let query = query(account)
                let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(code.utf8)] as CFDictionary)
                if update == errSecItemNotFound {
                    var item = query
                    item[kSecValueData as String] = Data(code.utf8)
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    let status = SecItemAdd(item as CFDictionary, nil)
                    guard status == errSecSuccess else { throw QQMailboxError.keychain(status) }
                } else if update != errSecSuccess { throw QQMailboxError.keychain(update) }
            }
            if enabled, try readCode(account).isEmpty { throw QQMailboxError.missingCode }
        }
        UserDefaults.standard.set(account, forKey: prefix + "address")
        UserDefaults.standard.set(enabled, forKey: prefix + "enabled")
        UserDefaults.standard.set(Calendar.current.startOfDay(for: since), forKey: prefix + "since")
        revision += 1
    }
    public static func credentials() throws -> QQMailboxCredentials {
        try QQMailboxCredentials(address: address, authorizationCode: readCode(address))
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private static func readCode(_ account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw QQMailboxError.keychain(status) }
        guard let data = result as? Data, let code = String(data: data, encoding: .utf8) else { throw QQMailboxError.missingCode }
        return code
    }
}

public struct MailAttachmentReference: Codable, Sendable, Equatable {
    public let account: String
    public let uidValidity: String
    public let uid: UInt64
    public let partID: String
    public let encoding: String
    public let size: Int
}
public struct InvoiceMailAttachment: Codable, Sendable {
    public let filename: String
    public let remote: MailAttachmentReference
}
public struct InvoiceMailMessage: Sendable {
    public let id: String
    public let receivedAt: Date
    public let subject: String
    public let sender: String
    public let attachments: [InvoiceMailAttachment]
    public let hasDownloadLink: Bool
}

public enum QQMailboxClient {
    public static func test(credentials: QQMailboxCredentials) async throws {
        let session = MailSession()
        defer { session.close() }
        try await session.connect()
        try await session.login(credentials)
        _ = try await session.command("EXAMINE INBOX")
    }

    public static func fetch(credentials: QQMailboxCredentials, since: Date, excluding: Set<String>,
                             receive: @Sendable (InvoiceMailMessage) async throws -> Void) async throws {
        let session = MailSession()
        defer { session.close() }
        try await session.connect()
        try await session.login(credentials)
        let examined = try await session.command("EXAMINE INBOX")
        let validity = try QQMailboxParser.uidValidity(examined)
        let since = Calendar.current.startOfDay(for: since)
        let search = try await session.command("UID SEARCH SINCE \(searchDate(since))")
        let ids = QQMailboxParser.searchIDs(search)
        for uid in ids {
            try Task.checkCancellation()
            let id = "\(credentials.address)|\(validity)|\(uid)"
            if excluding.contains(id) { continue }
            let metadata = try await session.command("UID FETCH \(uid) (INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM)])")
            let message = try QQMailboxParser.message(metadata, account: credentials.address, uidValidity: validity, uid: uid)
            guard message.receivedAt >= since else { continue }
            // Fetch metadata first; the sync controller decides which new attachments to download.
            try await receive(message)
        }
    }

    static func fetchBody(credentials: QQMailboxCredentials, id: String) async throws -> MailBody {
        let identity = try MailMessageIdentity(id: id)
        guard identity.account == credentials.address else { throw QQMailboxError.changedMailbox }
        let session = MailSession()
        defer { session.close() }
        try await session.connect()
        try await session.login(credentials)
        let examined = try await session.command("EXAMINE INBOX")
        guard try QQMailboxParser.uidValidity(examined) == identity.validity else { throw QQMailboxError.changedMailbox }
        let metadata = try await session.command("UID FETCH \(identity.uid) (BODYSTRUCTURE)")
        let parts = try QQMailboxParser.bodyParts(metadata)
        let texts = parts.filter { $0.mime.hasPrefix("text/") }
        guard let part = texts.last(where: { $0.mime == "text/html" }) ?? texts.first else { return MailBody(text: "", html: nil) }
        guard part.size <= 2 * 1024 * 1024 else { throw QQMailboxError.tooLarge }
        func load(_ part: QQMailboxParser.BodyPart) async throws -> Data {
            let response = try await session.command("UID FETCH \(identity.uid) (BODY.PEEK[\(part.id)])", limit: 3 * 1024 * 1024)
            guard let encoded = QQMailboxParser.literals(response).first else { throw QQMailboxError.changedMailbox }
            return try QQMailboxParser.decodeAttachment(encoded, encoding: part.encoding)
        }
        var text = QQMailboxParser.decodeText(try await load(part), charset: part.charset)
        if part.mime == "text/html" {
            var total = 0
            for image in parts where image.cid != nil && image.mime.hasPrefix("image/") {
                guard let cid = image.cid, text.contains("cid:" + cid), image.size <= 512 * 1024,
                      total + image.size <= 2 * 1024 * 1024 else { continue }
                let bytes = try await load(image)
                guard bytes.count <= 512 * 1024 else { continue }
                total += bytes.count
                text = text.replacingOccurrences(of: "cid:" + cid, with: "data:" + image.mime + ";base64," + bytes.base64EncodedString())
            }
            return MailBody(text: "", html: text)
        }
        return MailBody(text: text, html: nil)
    }

    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    public static func fetchAttachment(credentials: QQMailboxCredentials, reference: MailAttachmentReference) async throws -> Data {
        guard credentials.address == reference.account, reference.uid > 0,
              reference.partID.range(of: #"^[1-9][0-9]*(?:\.[1-9][0-9]*)*$"#, options: .regularExpression) != nil,
              reference.size >= 0, reference.size <= 30 * 1024 * 1024 else { throw QQMailboxError.changedMailbox }
        let session = MailSession()
        defer { session.close() }
        try await session.connect()
        try await session.login(credentials)
        let examined = try await session.command("EXAMINE INBOX")
        guard try QQMailboxParser.uidValidity(examined) == reference.uidValidity else { throw QQMailboxError.changedMailbox }
        let response = try await session.command("UID FETCH \(reference.uid) (BODY.PEEK[\(reference.partID)])", limit: 40 * 1024 * 1024)
        guard let encoded = QQMailboxParser.literals(response).first else { throw QQMailboxError.changedMailbox }
        let data = try QQMailboxParser.decodeAttachment(encoded, encoding: reference.encoding)
        guard data.count <= 30 * 1024 * 1024 else { throw QQMailboxError.tooLarge }
        return data
    }
}

// Each session has one sequential caller; Network owns its TLS connection on a private queue.
private final class MailSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "top.kjoe.qqmail")
    private let connection = NWConnection(host: "imap.qq.com", port: 993, using: .tls)
    private var buffer = Data()
    private var sequence = 0
    func close() { connection.cancel() }

    func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = MailOnce(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: completion.finish(.success(()))
                    case .failed, .cancelled: completion.finish(.failure(QQMailboxError.connection))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + 30) { [connection] in
                    if completion.finish(.failure(QQMailboxError.connection)) { connection.cancel() }
                }
                connection.start(queue: queue)
            }
            let greeting = try await readLine(limit: 65536)
            guard String(decoding: greeting, as: UTF8.self).uppercased().hasPrefix("* OK") else { throw QQMailboxError.rejected }
        } onCancel: { self.connection.cancel() }
    }
    func login(_ credentials: QQMailboxCredentials) async throws {
        let capability = String(decoding: try await command("CAPABILITY"), as: UTF8.self)
        if capability.range(of: #"(?:^|[ \r\n])ID(?:[ \r\n]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            _ = try await command("ID (\"name\" \"ReimbursementAssistant\" \"version\" \"1\")")
        }
        _ = try await command("LOGIN \(quoted(credentials.address)) \(quoted(credentials.authorizationCode))")
    }
    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    func command(_ command: String, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        try Task.checkCancellation()
        sequence += 1
        let tag = "R\(sequence)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = MailOnce(continuation)
                queue.asyncAfter(deadline: .now() + 60) { [connection] in
                    if completion.finish(.failure(QQMailboxError.connection)) { connection.cancel() }
                }
                connection.send(content: Data("\(tag) \(command)\r\n".utf8), completion: .contentProcessed { error in
                    if error != nil { completion.finish(.failure(QQMailboxError.connection)) }
                    else { completion.finish(.success(())) }
                })
            }
            var response = Data()
            while true {
                let line = try await readLine(limit: min(limit, 256 * 1024))
                response.append(line)
                guard response.count <= limit else { throw QQMailboxError.tooLarge }
                let text = String(decoding: line, as: UTF8.self)
                if text.hasPrefix(tag + " ") {
                    guard text.uppercased().hasPrefix(tag.uppercased() + " OK") else { throw QQMailboxError.rejected }
                    return response
                }
                if let count = QQMailboxParser.literalCount(text) {
                    guard count <= limit - response.count else { throw QQMailboxError.tooLarge }
                    while buffer.count < count { try await receiveMore() }
                    response.append(buffer.prefix(count))
                    buffer.removeFirst(count)
                }
            }
        } onCancel: { self.connection.cancel() }
    }
    private func readLine(limit: Int) async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = Data(buffer[..<range.upperBound])
                buffer.removeSubrange(..<range.upperBound)
                return line
            }
            guard buffer.count <= limit else { throw QQMailboxError.tooLarge }
            try await receiveMore()
        }
    }
    private func receiveMore() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = MailOnce(continuation)
            queue.asyncAfter(deadline: .now() + 60) { [connection] in
                if completion.finish(.failure(QQMailboxError.connection)) { connection.cancel() }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty { completion.finish(.success(data)) }
                else if complete || error != nil { completion.finish(.failure(QQMailboxError.connection)) }
                else { completion.finish(.failure(QQMailboxError.connection)) }
            }
        }
        buffer.append(data)
    }
}

private final class MailOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}
