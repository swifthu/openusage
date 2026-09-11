import XCTest
@testable import OpenUsage

final class MiniMaxAuthStoreTests: XCTestCase {
    func testEnvironmentKeyPrecedence() {
        let store = MiniMaxAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-env")
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = MiniMaxAuthStore(
            files: files,
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )

        try store.saveAPIKey("minimax-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testReadsJSONConfigFile() {
        let store = MiniMaxAuthStore(
            files: FakeFiles([MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-json"}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-json")
    }

    func testReadsPlainTextConfigFile() {
        let store = MiniMaxAuthStore(
            files: FakeFiles([MiniMaxAuthStore.configPaths[0]: "  minimax-plain\n"]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-plain")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let store = MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? MiniMaxAuthError, .missingKey)
        }
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["MINIMAX_API_KEY": "minimax-env"]
        let file = [MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-file"}"#]

        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(),
            .notSet
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(),
            .fromEnvironment
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(),
            .saved
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(),
            .overrideActive
        )
    }

    func testDeleteClearsConfigFileAndPreservesEnvironmentFallback() throws {
        let files = FakeFiles([MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-file"}"#])
        let store = MiniMaxAuthStore(
            files: files,
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )

        try store.deleteAPIKey()

        XCTAssertNil(files.files[MiniMaxAuthStore.configPaths[0]])
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }
}
