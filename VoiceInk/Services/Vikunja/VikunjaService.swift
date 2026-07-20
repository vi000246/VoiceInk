import Foundation

/// Vikunja REST client(最小面:建任務、列專案、驗證連線)。
///
/// 錯誤分 transient(5xx / 網路層)與 permanent(4xx),鏡射使用者 todo-list-manager
/// Python client 的分法——permanent 是設定/權限問題,重試無意義。
/// `URLSession` 注入,測試用 `URLProtocol` stub 完全不出網路。
enum VikunjaError: Error, LocalizedError, Equatable {
    case invalidURL
    /// 5xx 或網路層失敗(理論上可重試)。status nil = 沒拿到 HTTP 回應。
    case transient(status: Int?, message: String)
    /// 4xx(token 錯、專案不存在等設定問題)。
    case permanent(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Vikunja URL 無效"
        case .transient(let status, let message):
            return "Vikunja 連線失敗(\(status.map(String.init) ?? "網路")):\(message)"
        case .permanent(let status, let message):
            return "Vikunja 拒絕請求(\(status)):\(message)"
        }
    }
}

final class VikunjaService {

    struct Project: Decodable, Identifiable, Equatable {
        let id: Int
        let title: String
    }

    struct CreatedTask: Decodable, Equatable {
        let id: Int
        let title: String
    }

    /// `listOpenTasks` 的最小任務面。`dueDateRaw` 保留原始字串——Vikunja 用
    /// "0001-01-01…" 當「未設定」sentinel,由呼叫端(`BriefingContent.parseDueDate`)判讀。
    struct TaskItem: Decodable, Equatable, Identifiable {
        let id: Int
        let title: String
        let done: Bool
        let dueDateRaw: String?

        private enum CodingKeys: String, CodingKey {
            case id, title, done
            case dueDateRaw = "due_date"
        }

        init(id: Int, title: String, done: Bool = false, dueDateRaw: String? = nil) {
            self.id = id
            self.title = title
            self.done = done
            self.dueDateRaw = dueDateRaw
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
            dueDateRaw = try c.decodeIfPresent(String.self, forKey: .dueDateRaw)
        }
    }

    private let apiBase: String
    private let token: String
    private let session: URLSession

    init(baseURL: String, token: String, session: URLSession = .shared) {
        self.apiBase = Self.normalizeBaseURL(baseURL)
        self.token = token
        self.session = session
    }

    // MARK: - URL 正規化(純函式)

    /// 去尾端斜線;未含 /api/v1 就補上(Vikunja API 路徑固定以 /api/v1 開頭)。
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return s }
        if !s.hasSuffix("/api/v1") { s += "/api/v1" }
        return s
    }

    /// Web UI 的 base(通知「打開」按鈕用):即正規化後去掉 /api/v1。
    static func uiBaseURL(_ raw: String) -> String {
        var s = normalizeBaseURL(raw)
        if s.hasSuffix("/api/v1") { s.removeLast("/api/v1".count) }
        return s
    }

    // MARK: - 日期編碼

    /// RFC3339 含 +08:00 位移——Vikunja 端有 Google Calendar 同步,時刻正確是本功能核心價值。
    static let dueDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        return formatter
    }()

    // MARK: - API

    /// PUT {base}/projects/{projectId}/tasks。`dueDate` nil 時**整個欄位不送**——
    /// Vikunja 用 "0001-01-01T00:00:00Z" 當「未設定」sentinel,送了假日期會生出假行事曆事件。
    func createTask(
        projectId: Int,
        title: String,
        description: String,
        dueDate: Date?,
        priority: Int
    ) async throws -> CreatedTask {
        struct Body: Encodable {
            let title: String
            let description: String
            let due_date: String?
            let priority: Int
        }
        let body = Body(
            title: title,
            description: description,
            due_date: dueDate.map { Self.dueDateFormatter.string(from: $0) },
            priority: priority
        )
        let data = try await request(
            path: "/projects/\(projectId)/tasks",
            method: "PUT",
            body: try JSONEncoder().encode(body)
        )
        return try decode(CreatedTask.self, from: data)
    }

    /// GET {base}/projects(設定頁的專案下拉)。
    func listProjects() async throws -> [Project] {
        let data = try await request(path: "/projects", method: "GET", body: nil)
        return try decode([Project].self, from: data)
    }

    /// GET {base}/user——token 與 URL 都對才會 200。
    func verifyConnection() async throws {
        _ = try await request(path: "/user", method: "GET", body: nil)
    }

    /// 分頁保險上限(50 頁 × 250 筆 = 12,500 筆,個人待辦不可能到)。
    static let maxTaskPages = 50

    /// GET {base}/tasks/all,filter='done = false',逐頁抓到**空頁**為止。
    ///
    /// 分頁/filter/sentinel 慣例鏡射使用者自己的 Python client:終止條件必須是空頁、
    /// 不能是「不足一頁」——伺服器端 maxitemsperpage 可能低於我們要的 250,每頁實拿
    /// 筆數不可信,只有空頁才代表抓完了。
    func listOpenTasks() async throws -> [TaskItem] {
        var all: [TaskItem] = []
        for page in 1...Self.maxTaskPages {
            let data = try await request(path: "/tasks/all", method: "GET", body: nil, queryItems: [
                URLQueryItem(name: "filter", value: "done = false"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "250"),
            ])
            let batch = try decode([TaskItem].self, from: data)
            if batch.isEmpty { break }
            all.append(contentsOf: batch)
        }
        return all
    }

    // MARK: - Transport

    private func request(
        path: String, method: String, body: Data?, queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        guard !apiBase.isEmpty, var comps = URLComponents(string: apiBase + path) else {
            throw VikunjaError.invalidURL
        }
        // filter 值含空白/等號,URLComponents 的 queryItems 會自動 percent-encode;手拼會生非法 URL。
        if let queryItems { comps.queryItems = queryItems }
        guard let url = comps.url else {
            throw VikunjaError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw VikunjaError.transient(status: nil, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VikunjaError.transient(status: nil, message: "非 HTTP 回應")
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            return data
        case 400..<500:
            throw VikunjaError.permanent(status: http.statusCode, message: String(bodyText.prefix(200)))
        default:
            throw VikunjaError.transient(status: http.statusCode, message: String(bodyText.prefix(200)))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VikunjaError.transient(status: nil, message: "回應解析失敗:\(error.localizedDescription)")
        }
    }
}
