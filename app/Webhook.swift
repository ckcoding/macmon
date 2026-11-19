// MacMon — Webhook 推送（企业微信 / 钉钉 / 飞书 / Slack / 自定义 JSON）
//
// 防卡死：独立 URLSession（短超时、不等网络恢复），回调在后台；在途请求有上限，网络差时直接丢弃而不是堆积。
import Foundation
import CryptoKit
import SystemConfiguration

enum HookKind: String, CaseIterable, Codable, Identifiable {
    case wecom, dingtalk, feishu, slack, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wecom: return "企业微信"
        case .dingtalk: return "钉钉"
        case .feishu: return "飞书"
        case .slack: return "Slack"
        case .custom: return "自定义 JSON"
        }
    }

    var symbol: String {
        switch self {
        case .wecom: return "message.fill"
        case .dingtalk: return "bell.fill"
        case .feishu: return "paperplane.fill"
        case .slack: return "number"
        case .custom: return "curlybraces"
        }
    }

    var placeholder: String {
        switch self {
        case .wecom: return "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…"
        case .dingtalk: return "https://oapi.dingtalk.com/robot/send?access_token=…"
        case .feishu: return "https://open.feishu.cn/open-apis/bot/v2/hook/…"
        case .slack: return "https://hooks.slack.com/services/…"
        case .custom: return "https://your-server/macmon"
        }
    }

    /// 是否支持「加签」密钥
    var hasSecret: Bool { self == .dingtalk || self == .feishu }

    var howTo: String {
        switch self {
        case .wecom: return "群聊 → 右上角 ⋯ → 群机器人 → 添加机器人 → 复制 Webhook 地址"
        case .dingtalk: return "群设置 → 机器人 → 添加自定义机器人。安全设置选「加签」并把密钥填到下方，或选「自定义关键词」填 MacMon"
        case .feishu: return "群设置 → 群机器人 → 添加机器人 → 自定义机器人。开了签名校验就把密钥填到下方"
        case .slack: return "Slack App → Incoming Webhooks → Add New Webhook to Workspace"
        case .custom: return "POST JSON：{source, host, title, body, category, time}"
        }
    }
}

struct Webhook: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: HookKind
    var url: String = ""
    var secret: String = ""
    var enabled: Bool = true
}

enum Hooks {
    static let key = "webhooks"
    static let localOn = "systemNotifyOn"
    /// 资源报警（CPU/内存/Swap/磁盘/自我恢复…）是否通知；默认关闭，只在即将自动结束应用前通知
    static let alertsOn = "alertNotifyOn"

    static func load(_ d: UserDefaults = .standard) -> [Webhook] {
        guard let data = d.data(forKey: key), let v = try? JSONDecoder().decode([Webhook].self, from: data) else { return [] }
        return v
    }

    static func save(_ hooks: [Webhook], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(hooks) { d.set(data, forKey: key) }
    }
}

/// 电脑名称（「系统设置 → 通用 → 关于本机」里的名字），本地读取，不走 DNS
let computerName: String = {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}()

final class WebhookSender {
    static let shared = WebhookSender()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false        // 没网就立刻失败，不挂起等待
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private let lock = NSLock()
    private var inflight = 0
    private let maxInflight = 8

    /// 推送给所有已启用的 Webhook（报警用，结果只写日志）
    func broadcast(category: String, title: String, body: String, log: ((String) -> Void)? = nil) {
        for h in Hooks.load() where h.enabled && !h.url.isEmpty {
            send(h, category: category, title: title, body: body) { ok, msg in
                if !ok { log?("Webhook（\(h.kind.title)）发送失败：\(msg)") }
            }
        }
    }

    /// 测试单个 Webhook，返回（成功？说明）
    func test(_ h: Webhook) async -> (Bool, String) {
        await withCheckedContinuation { c in
            send(h, category: "test", title: "✅ MacMon 测试消息",
                 body: "Webhook 配置成功。之后 CPU / 内存 / Swap 异常、自动结束应用等都会推送到这里。") { ok, msg in
                c.resume(returning: (ok, msg))
            }
        }
    }

    func send(_ h: Webhook, category: String, title: String, body: String,
              completion: @escaping (_ ok: Bool, _ msg: String) -> Void) {
        guard let req = Self.request(h, category: category, title: title, body: body) else {
            completion(false, "地址无效（需要以 https:// 开头）"); return
        }
        lock.lock()
        guard inflight < maxInflight else { lock.unlock(); completion(false, "发送队列已满，已丢弃"); return }
        inflight += 1
        lock.unlock()
        session.dataTask(with: req) { [weak self] data, resp, err in
            self?.lock.lock(); self?.inflight -= 1; self?.lock.unlock()
            if let e = err { completion(false, e.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let (ok, msg) = Self.judge(h.kind, code: code, data: data)
            completion(ok, msg)
        }.resume()
    }

    // MARK: - 组装请求

    static func message(title: String, body: String) -> String {
        "【MacMon · \(computerName)】\(title)\n\(body)\n\(iso.string(from: Date()))"
    }

    static func request(_ h: Webhook, category: String, title: String, body: String) -> URLRequest? {
        var urlStr = h.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u0 = URL(string: urlStr), let scheme = u0.scheme?.lowercased(), let host = u0.host else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && (local || h.kind == .custom)) else { return nil }

        let text = message(title: title, body: body)
        var payload: [String: Any]
        switch h.kind {
        case .wecom:
            payload = ["msgtype": "text", "text": ["content": text]]
        case .dingtalk:
            payload = ["msgtype": "text", "text": ["content": text]]
            if !h.secret.isEmpty {
                // 钉钉加签：sign = urlEncode(base64(HmacSHA256(key: secret, msg: "timestamp\nsecret")))
                let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
                let mac = HMAC<SHA256>.authenticationCode(for: Data("\(ts)\n\(h.secret)".utf8), using: SymmetricKey(data: Data(h.secret.utf8)))
                let sign = Data(mac).base64EncodedString()
                    .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                urlStr += (urlStr.contains("?") ? "&" : "?") + "timestamp=\(ts)&sign=\(sign)"
            }
        case .feishu:
            payload = ["msg_type": "text", "content": ["text": text]]
            if !h.secret.isEmpty {
                // 飞书签名：sign = base64(HmacSHA256(key: "timestamp\nsecret", msg: 空))
                let ts = String(Int64(Date().timeIntervalSince1970))
                let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: SymmetricKey(data: Data("\(ts)\n\(h.secret)".utf8)))
                payload["timestamp"] = ts
                payload["sign"] = Data(mac).base64EncodedString()
            }
        case .slack:
            payload = ["text": text]
        case .custom:
            payload = ["source": "MacMon", "host": computerName, "title": title, "body": body,
                       "category": category, "time": ISO8601DateFormatter().string(from: Date())]
        }
        guard let url = URL(string: urlStr), let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue("MacMon/\(VERSION)", forHTTPHeaderField: "User-Agent")
        r.httpBody = data
        return r
    }

    /// 各平台成功判定：HTTP 200 不代表成功，企业微信/钉钉看 errcode，飞书看 code
    static func judge(_ kind: HookKind, code: Int, data: Data?) -> (Bool, String) {
        let raw = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
        guard (200..<300).contains(code) else { return (false, "HTTP \(code) \(raw)") }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch kind {
        case .wecom, .dingtalk:
            let e = (json?["errcode"] as? Int) ?? -1
            return e == 0 ? (true, "发送成功") : (false, "errcode \(e)：\(json?["errmsg"] as? String ?? String(raw))")
        case .feishu:
            let c = (json?["code"] as? Int) ?? (json?["StatusCode"] as? Int) ?? -1
            return c == 0 ? (true, "发送成功") : (false, "code \(c)：\(json?["msg"] as? String ?? String(raw))")
        case .slack, .custom:
            return (true, "发送成功（HTTP \(code)）")
        }
    }
}
