import XCTest
@testable import DSHMobile

final class AppStoreTests: XCTestCase {
    @MainActor
    func testMockConnectAndStream() async throws {
        let store = AppStore(client: MockDSHClient())
        await store.connect(with: ServerConfig(tokenURL: "http://127.0.0.1:8328/?token=x"))
        XCTAssertTrue(store.connection.connectedForTesting)
        await store.refresh()
        XCTAssertFalse(store.conversations.isEmpty)
        let convo = store.conversations[0]
        await store.open(convo)
        store.send("ping")
        // Let the mock stream settle.
        try await Task.sleep(for: .seconds(3))
        store.streamTask?.cancel()
        XCTAssertEqual(store.messages.count, 4)
        XCTAssertFalse(store.messages[3].isStreaming)
        XCTAssertFalse(store.messages[3].text.isEmpty)
    }

    @MainActor
    func testArchiveToggle() async throws {
        let store = AppStore(client: MockDSHClient())
        await store.refresh()
        let convo = store.conversations[0]
        XCTAssertFalse(store.isArchived(convo.id))
        store.toggleArchive(convo.id)
        XCTAssertTrue(store.isArchived(convo.id))
        store.toggleArchive(convo.id)
        XCTAssertFalse(store.isArchived(convo.id))
    }
}

private extension AppStore.ConnectionState {
    var connectedForTesting: Bool {
        if case .connected = self { return true }
        return false
    }
}
