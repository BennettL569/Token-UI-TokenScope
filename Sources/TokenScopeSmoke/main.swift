import Foundation
import TokenScopeCore

@main
struct TokenScopeSmoke {
    static func main() async throws {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-smoke-\(UUID().uuidString).sqlite")
        let store = UsageStore(repository: PersistentUsageRepository(dbURL: dbURL))
        await store.refreshAll()
        print("first_records=\(store.records.count)")
        for source in store.sources {
            print("first \(source.tool.rawValue): \(source.syncStatus.kind.rawValue) \(source.syncStatus.message)")
        }
        await store.refreshAll()
        print("second_records=\(store.records.count)")
        for source in store.sources {
            print("second \(source.tool.rawValue): \(source.syncStatus.kind.rawValue) \(source.syncStatus.message)")
        }
    }
}
