import XCTest
@testable import VoiceInk

/// Vikunja client:URLProtocol stub 完全不出網路。
/// 驗證建任務請求形狀/回應解析、4xx→permanent、5xx與網路→transient、URL 正規化。
final class VikunjaServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockVikunjaProtocol.reset()
    }

    private func makeService(baseURL: String = "https://vikunja.example.com") -> VikunjaService {
        VikunjaService(baseURL: baseURL, token: "tok-123", session: MockVikunjaProtocol.makeSession())
    }

    // MARK: - createTask

    func testCreateTaskSuccessParsesIdAndSendsExpectedRequest() async throws {
        MockVikunjaProtocol.body = #"{"id": 42, "title": "買牛奶"}"#

        let task = try await makeService().createTask(
            projectId: 7, title: "買牛奶", description: "順便買蛋", dueDate: nil, priority: 3)

        XCTAssertEqual(task.id, 42)
        XCTAssertEqual(task.title, "買牛奶")

        let request = try XCTUnwrap(MockVikunjaProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://vikunja.example.com/api/v1/projects/7/tasks")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(MockVikunjaProtocol.lastBodyJSON())
        XCTAssertEqual(body["title"] as? String, "買牛奶")
        XCTAssertEqual(body["description"] as? String, "順便買蛋")
        XCTAssertEqual(body["priority"] as? Int, 3)
        // dueDate nil → 欄位整個不送(Vikunja 用 0001-01-01 當未設定 sentinel,不能送假日期)。
        XCTAssertNil(body["due_date"] ?? nil)
    }

    func testCreateTaskEncodesDueDateAsTaipeiRFC3339() async throws {
        MockVikunjaProtocol.body = #"{"id": 1, "title": "t"}"#

        // 2026-07-18T15:00:00+08:00 == 2026-07-18T07:00:00Z
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 18; components.hour = 7
        components.timeZone = TimeZone(identifier: "UTC")
        let due = Calendar(identifier: .gregorian).date(from: components)!

        _ = try await makeService().createTask(
            projectId: 1, title: "t", description: "", dueDate: due, priority: 0)

        let body = try XCTUnwrap(MockVikunjaProtocol.lastBodyJSON())
        XCTAssertEqual(body["due_date"] as? String, "2026-07-18T15:00:00+08:00")
    }

    // MARK: - 錯誤分類

    func test4xxThrowsPermanent() async {
        MockVikunjaProtocol.status = 401
        MockVikunjaProtocol.body = "invalid token"
        do {
            _ = try await makeService().createTask(
                projectId: 1, title: "t", description: "", dueDate: nil, priority: 0)
            XCTFail("應 throw")
        } catch let error as VikunjaError {
            guard case .permanent(let status, let message) = error else {
                return XCTFail("錯誤類別: \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("invalid token"))
        } catch { XCTFail("錯誤型別: \(error)") }
    }

    func test5xxThrowsTransient() async {
        MockVikunjaProtocol.status = 502
        do {
            _ = try await makeService().listProjects()
            XCTFail("應 throw")
        } catch let error as VikunjaError {
            guard case .transient(let status, _) = error else {
                return XCTFail("錯誤類別: \(error)")
            }
            XCTAssertEqual(status, 502)
        } catch { XCTFail("錯誤型別: \(error)") }
    }

    func testNetworkFailureThrowsTransientWithoutStatus() async {
        MockVikunjaProtocol.networkError = URLError(.notConnectedToInternet)
        do {
            try await makeService().verifyConnection()
            XCTFail("應 throw")
        } catch let error as VikunjaError {
            guard case .transient(let status, _) = error else {
                return XCTFail("錯誤類別: \(error)")
            }
            XCTAssertNil(status)
        } catch { XCTFail("錯誤型別: \(error)") }
    }

    // MARK: - listProjects / verifyConnection

    func testListProjectsParsesArray() async throws {
        MockVikunjaProtocol.body = #"[{"id":1,"title":"Inbox"},{"id":5,"title":"工作"}]"#
        let projects = try await makeService().listProjects()
        XCTAssertEqual(projects, [
            VikunjaService.Project(id: 1, title: "Inbox"),
            VikunjaService.Project(id: 5, title: "工作"),
        ])
        XCTAssertEqual(MockVikunjaProtocol.lastRequest?.url?.absoluteString,
                       "https://vikunja.example.com/api/v1/projects")
    }

    func testVerifyConnectionHitsUserEndpoint() async throws {
        MockVikunjaProtocol.body = #"{"id": 1, "username": "logan"}"#
        try await makeService().verifyConnection()
        XCTAssertEqual(MockVikunjaProtocol.lastRequest?.url?.absoluteString,
                       "https://vikunja.example.com/api/v1/user")
        XCTAssertEqual(MockVikunjaProtocol.lastRequest?.httpMethod, "GET")
    }

    // MARK: - listOpenTasks(分頁 + filter)

    func testListOpenTasksPaginatesUntilEmptyPage() async throws {
        MockVikunjaProtocol.bodyQueue = [
            #"[{"id":1,"title":"a","done":false},{"id":2,"title":"b","done":false,"due_date":"0001-01-01T00:00:00Z"}]"#,
            #"[{"id":3,"title":"c","done":false,"due_date":"2026-07-21T09:00:00+08:00"}]"#,
            "[]",
        ]

        let tasks = try await makeService().listOpenTasks()

        XCTAssertEqual(tasks.map(\.id), [1, 2, 3])
        // 終止條件必須是空頁——不足一頁不可早退(伺服器 maxitemsperpage 可能低於 250)。
        XCTAssertEqual(MockVikunjaProtocol.requests.count, 3)

        for (index, request) in MockVikunjaProtocol.requests.enumerated() {
            let comps = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                                                    resolvingAgainstBaseURL: false))
            XCTAssertEqual(comps.path, "/api/v1/tasks/all")
            let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(items["filter"], "done = false")
            XCTAssertEqual(items["per_page"], "250")
            XCTAssertEqual(items["page"], String(index + 1))
            XCTAssertEqual(request.httpMethod, "GET")
        }
    }

    func testListOpenTasksKeepsSentinelDueDateRaw() async throws {
        MockVikunjaProtocol.bodyQueue = [
            #"[{"id":9,"title":"無期限","done":false,"due_date":"0001-01-01T00:00:00Z"}]"#,
            "[]",
        ]
        let tasks = try await makeService().listOpenTasks()
        // sentinel 原樣保留,由呼叫端(BriefingContent)判讀——service 不動語意。
        XCTAssertEqual(tasks.first?.dueDateRaw, "0001-01-01T00:00:00Z")
    }

    func testListOpenTasksStopsAtPageCap() async throws {
        // 永遠回非空頁 → 只能靠 50 頁保險上限煞車。
        MockVikunjaProtocol.body = #"[{"id":1,"title":"loop","done":false}]"#
        let tasks = try await makeService().listOpenTasks()
        XCTAssertEqual(MockVikunjaProtocol.requests.count, VikunjaService.maxTaskPages)
        XCTAssertEqual(tasks.count, VikunjaService.maxTaskPages)
    }

    func testListOpenTasksDecodesMissingOptionalFields() async throws {
        // done / due_date 缺欄不炸:done 預設 false、due nil。
        MockVikunjaProtocol.bodyQueue = [#"[{"id":4,"title":"minimal"}]"#, "[]"]
        let tasks = try await makeService().listOpenTasks()
        XCTAssertEqual(tasks, [VikunjaService.TaskItem(id: 4, title: "minimal")])
    }

    // MARK: - URL 正規化(純函式)

    func testNormalizeBaseURLAppendsAPIPath() {
        XCTAssertEqual(VikunjaService.normalizeBaseURL("https://x.example.com"),
                       "https://x.example.com/api/v1")
    }

    func testNormalizeBaseURLStripsTrailingSlashes() {
        XCTAssertEqual(VikunjaService.normalizeBaseURL("https://x.example.com///"),
                       "https://x.example.com/api/v1")
    }

    func testNormalizeBaseURLKeepsExistingAPIPath() {
        XCTAssertEqual(VikunjaService.normalizeBaseURL("https://x.example.com/api/v1"),
                       "https://x.example.com/api/v1")
        XCTAssertEqual(VikunjaService.normalizeBaseURL("https://x.example.com/api/v1/"),
                       "https://x.example.com/api/v1")
    }

    func testNormalizeBaseURLTrimsWhitespace() {
        XCTAssertEqual(VikunjaService.normalizeBaseURL("  https://x.example.com \n"),
                       "https://x.example.com/api/v1")
    }

    func testNormalizeBaseURLEmptyStaysEmpty() {
        XCTAssertEqual(VikunjaService.normalizeBaseURL("   "), "")
    }

    func testUIBaseURLStripsAPIPath() {
        XCTAssertEqual(VikunjaService.uiBaseURL("https://x.example.com/api/v1"), "https://x.example.com")
        XCTAssertEqual(VikunjaService.uiBaseURL("https://x.example.com/"), "https://x.example.com")
    }
}

/// 最小 URLProtocol stub:記下請求(含 body)、回放設定好的 status/body 或網路錯誤。
final class MockVikunjaProtocol: URLProtocol {
    static var status = 200
    static var body = ""
    /// 非空時逐請求出隊(分頁測試用);出隊完退回 `body`。
    static var bodyQueue: [String] = []
    static var networkError: Error?
    static var lastRequest: URLRequest?
    static var lastBodyData: Data?
    /// 依序記下所有請求(分頁測試要驗每頁參數)。
    static var requests: [URLRequest] = []

    static func reset() {
        status = 200; body = ""; bodyQueue = []; networkError = nil
        lastRequest = nil; lastBodyData = nil; requests = []
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockVikunjaProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func lastBodyJSON() -> [String: Any]? {
        guard let data = lastBodyData else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.requests.append(request)
        Self.lastBodyData = Self.drainBody(request)
        if let error = Self.networkError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let payload = Self.bodyQueue.isEmpty ? Self.body : Self.bodyQueue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 把 httpBody 轉成 stream 再交給 URLProtocol,所以要從 stream 撈。
    private static func drainBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
