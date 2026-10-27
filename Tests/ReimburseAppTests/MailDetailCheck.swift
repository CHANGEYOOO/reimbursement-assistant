#if DIRECT_TEST_RUNNER
import Foundation

@main struct MailDetailCheck {
    static func main() throws {
        let identity = try MailMessageIdentity(id: "a@qq.com|123|456")
        precondition(identity.uid == 456)
        for id in ["a@qq.com|1|0", "a@qq.com|x|4", "a@qq.com|1|4 UID STORE", "a@qq.com|1|4|5"] {
            do { _ = try MailMessageIdentity(id: id); preconditionFailure("Invalid identity accepted") }
            catch {}
        }
        let structure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 8 1 NIL NIL)("TEXT" "HTML" ("CHARSET" "GBK") NIL NIL "BASE64" 80 1 NIL NIL)("IMAGE" "PNG" ("NAME" "logo.png") "<logo>" NIL "BASE64" 40 NIL ("INLINE" NIL))("APPLICATION" "PDF" NIL NIL NIL "BASE64" 999 NIL ("ATTACHMENT" NIL)) "MIXED")"#
        let parts = try QQMailboxParser.bodyParts(Data(("* 1 FETCH (BODYSTRUCTURE " + structure + ")\r\nA1 OK\r\n").utf8))
        precondition(parts.count == 3 && parts[1].charset == "GBK")
        precondition(parts[2].id == "3" && parts[2].cid == "logo")
        let decoded = try QQMailboxParser.decodeAttachment(Data("=E5=8F=91=E7=A5=A8".utf8), encoding: "QUOTED-PRINTABLE")
        precondition(decoded == Data("发票".utf8))
        let body = MailBody(text: "", html: #"<script>fetch('https://evil.test')</script><iframe src="https://evil.test"></iframe><img src="https://evil.test/pixel"><a href="https://seller.test/invoice?a=1&amp;b=2">下载</a><a href="javascript:alert(1)">invoice</a><a href="file:///private/test.pdf">invoice</a>"#)
        precondition(body.links.map(\.absoluteString) == ["https://seller.test/invoice?a=1&b=2"])
        precondition(body.safeHTML.contains("default-src 'none'") && body.safeHTML.contains("img-src data:") && body.safeHTML.contains("form-action 'none'"))
        for url in ["javascript:alert(1)", "file:///test.pdf", "data:text/html,hi", "https://user:pass@example.com/invoice"] { precondition(MailBody.externalURL(url) == nil) }
        precondition(MailBody.externalURL("https://example.com/invoice") != nil)
        let rules = try JSONSerialization.jsonObject(with: Data(MailHTMLSecurity.rulesJSON.utf8)) as! [[String: Any]]
        precondition((rules[0]["action"] as? [String: String])?["type"] == "block")
        let trigger = rules[0]["trigger"] as! [String: Any]
        precondition(trigger["url-filter"] as? String == "^https?://")
        precondition(trigger["url-filter-is-case-sensitive"] as? Bool == false)
        let sameHost = MailBody(text: "https://seller.test/invoice/one https://seller.test/invoice/two", html: nil)
        precondition(sameHost.links.count == 2 && sameHost.links[0].path != sameHost.links[1].path)
        print("Mail detail identity, MIME, candidate links and CSP checks passed (offline)")
    }
}
#endif
