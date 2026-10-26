#if DIRECT_TEST_RUNNER
import Foundation

@main struct QQMailboxCheck {
    static func main() throws {
        let structure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 42 2 NIL NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "=?UTF-8?B?55S15a2Q5Y+R56WoLnBkZg==?=") NIL NIL "BASE64" 120 NIL ("ATTACHMENT" ("FILENAME" "=?UTF-8?B?55S15a2Q5Y+R56WoLnBkZg==?=")) NIL NIL) "MIXED" ("BOUNDARY" "x") NIL NIL NIL)"#
        let header = "Subject: =?UTF-8?B?55S15a2Q5Y+R56Wo?=\r\nFrom: merchant@example.com\r\n\r\n"
        let reply = "* 1 FETCH (UID 8 INTERNALDATE \"26-Oct-2026 11:57:06 +0800\" BODYSTRUCTURE \(structure) BODY[HEADER.FIELDS (SUBJECT FROM)] {\(header.utf8.count)}\r\n\(header))\r\nA1 OK done\r\n"
        let message = try QQMailboxParser.message(Data(reply.utf8), account: "test@qq.com", uidValidity: "7", uid: 8)
        precondition(message.subject == "电子发票" && message.attachments.count == 1)
        precondition(message.attachments[0].filename == "电子发票.pdf")
        precondition(message.attachments[0].remote.partID == "2" && message.attachments[0].remote.uid == 8)
        precondition(message.receivedAt == ISO8601DateFormatter().date(from: "2026-10-26T03:57:06Z")!)
        precondition(message.id == "test@qq.com|7|8")
        precondition(QQMailboxParser.decodeWords("=?UTF-8?Q?=E5=8F=91=E7=A5=A8.pdf?=") == "发票.pdf")
        let base64 = try QQMailboxParser.decodeAttachment(Data("YWJj\r\n".utf8), encoding: "BASE64")
        precondition(base64 == Data("abc".utf8))
        let quoted = try QQMailboxParser.decodeAttachment(Data("a=3Db=0A".utf8), encoding: "QUOTED-PRINTABLE")
        precondition(quoted == Data("a=b\n".utf8))
        let rfc2231 = #"("APPLICATION" "PDF" NIL NIL NIL "BASE64" 24 NIL ("ATTACHMENT" ("FILENAME*0*" "UTF-8''%E5%8F%91" "FILENAME*1*" "%E7%A5%A8.pdf")) NIL NIL)"#
        let extended = reply.replacingOccurrences(of: structure, with: rfc2231)
        let named = try QQMailboxParser.message(Data(extended.utf8), account: "test@qq.com", uidValidity: "7", uid: 8)
        precondition(named.attachments.first?.filename == "发票.pdf")
        let encoded = try JSONEncoder().encode(message.attachments[0].remote)
        let restored = try JSONDecoder().decode(MailAttachmentReference.self, from: encoded)
        precondition(restored == message.attachments[0].remote)
        let payload = Data("first\r\nR1 OK not a command response\r\nlast".utf8)
        var framed = Data("* 1 FETCH (BODY[2] {\(payload.count)}\r\n".utf8)
        framed.append(payload)
        framed.append(Data(")\r\nR1 OK done\r\n".utf8))
        precondition(QQMailboxParser.literals(framed) == [payload], "Literal content must not be parsed as tagged command lines")
        let ordinaryHeader = header.replacingOccurrences(of: "=?UTF-8?B?55S15a2Q5Y+R56Wo?=", with: "Hello")
        let ordinary = reply.replacingOccurrences(of: "=?UTF-8?B?55S15a2Q5Y+R56Wo?=", with: "Hello")
            .replacingOccurrences(of: "=?UTF-8?B?55S15a2Q5Y+R56WoLnBkZg==?=", with: "manual.pdf")
            .replacingOccurrences(of: "{\(header.utf8.count)}", with: "{\(ordinaryHeader.utf8.count)}")
        let ordinaryMessage = try QQMailboxParser.message(Data(ordinary.utf8), account: "test@qq.com", uidValidity: "7", uid: 8)
        precondition(ordinaryMessage.attachments.isEmpty && ordinaryMessage.subject == "Hello")
        let start = Calendar.current.startOfDay(for: ISO8601DateFormatter().date(from: "2026-10-26T11:57:06Z")!)
        let expected = DateFormatter()
        expected.locale = Locale(identifier: "en_US_POSIX")
        expected.calendar = Calendar(identifier: .gregorian)
        expected.timeZone = .current
        expected.dateFormat = "dd-MMM-yyyy"
        precondition(QQMailboxClient.searchDate(start) == expected.string(from: start), "IMAP search uses the user's local calendar date")
        print("QQ mailbox metadata and encoding checks passed (offline, no mailbox or keychain access)")
    }
}
#endif
