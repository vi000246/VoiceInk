import XCTest
@testable import VoiceInk

@MainActor
final class TemplateStoreTests: XCTestCase {

    func testCustomPromptCategoriesCodableBackCompat() throws {
        // 舊 JSON（無 categories）解出 []
        let id = UUID()
        let legacy = "{\"id\":\"\(id.uuidString)\",\"title\":\"T\",\"promptText\":\"P\",\"useSystemInstructions\":true}"
            .data(using: .utf8)!
        let p = try JSONDecoder().decode(CustomPrompt.self, from: legacy)
        XCTAssertEqual(p.categories, [])
        // round-trip 保留
        var p2 = p; p2.categories = [.voiceInput, .recorderInput]
        let back = try JSONDecoder().decode(CustomPrompt.self, from: JSONEncoder().encode(p2))
        XCTAssertEqual(back.categories, [.voiceInput, .recorderInput])
    }

    func testCategoryFilter() {
        // 純函式：templates(for:) 過濾
        let store = TemplateStore.shared
        let backup = UserDefaults.standard.data(forKey: "sharedTemplatesV1")
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: "sharedTemplatesV1") }
            else { UserDefaults.standard.removeObject(forKey: "sharedTemplatesV1") }
            store.reload()
        }
        let voiceOnly = CustomPrompt(title: "V", promptText: "v", categories: [.voiceInput])
        let recOnly = CustomPrompt(title: "R", promptText: "r", categories: [.recorderInput])
        let both = CustomPrompt(title: "B", promptText: "b", categories: [.voiceInput, .recorderInput])
        store.upsert(voiceOnly); store.upsert(recOnly); store.upsert(both)

        let voiceIds = Set(store.templates(for: .voiceInput).map(\.id))
        XCTAssertTrue(voiceIds.contains(voiceOnly.id))
        XCTAssertTrue(voiceIds.contains(both.id))
        XCTAssertFalse(voiceIds.contains(recOnly.id))

        // cleanup inserted
        store.delete(voiceOnly.id); store.delete(recOnly.id); store.delete(both.id)
    }
}

@MainActor
final class TemplateMigrationTests: XCTestCase {

    func testMigratesAndPreservesBindingsIdempotent() throws {
        let d = UserDefaults.standard
        let keys = ["customPrompts", "recorderCategoryPromptsV1", "sharedTemplatesV1"]
        let backup = keys.map { ($0, d.data(forKey: $0)) }
        defer {
            for (k, v) in backup { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            TemplateStore.shared.reload()
        }

        let voice = CustomPrompt(title: "V", promptText: "v")
        let rec = CustomPrompt(title: "R", promptText: "r")
        d.set(try JSONEncoder().encode([voice]), forKey: "customPrompts")
        d.set(try JSONEncoder().encode([rec]), forKey: "recorderCategoryPromptsV1")
        d.removeObject(forKey: "sharedTemplatesV1")

        TemplateStore.shared.migrateIfNeeded()
        TemplateStore.shared.reload()
        XCTAssertEqual(TemplateStore.shared.template(byId: voice.id)?.categories, [.voiceInput])
        XCTAssertEqual(TemplateStore.shared.template(byId: rec.id)?.categories, [.recorderInput])

        let countAfterFirst = TemplateStore.shared.templates.count
        TemplateStore.shared.migrateIfNeeded()   // 冪等
        TemplateStore.shared.reload()
        XCTAssertEqual(TemplateStore.shared.templates.count, countAfterFirst)
    }
}
