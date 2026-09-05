import XCTest

final class SettingsTests: XCTestCase {
    func testInvalidFolderDoesNotReplacePreviousSelection() throws {
        let suite = "com.goldenrabbit.settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/previous-selection", forKey: "libraryDirectoryPath")
        let settings = Settings(defaults: defaults)
        XCTAssertThrowsError(try settings.setLibraryDirectory(URL(string: "https://example.invalid/folder")!))
        XCTAssertEqual(defaults.string(forKey: "libraryDirectoryPath"), "/previous-selection")
    }

}
