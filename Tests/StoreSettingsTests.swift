import XCTest

final class StoreSettingsTests: XCTestCase {
    func testInvalidFolderDoesNotReplacePreviousSelection() throws {
        let suite = "com.goldenrabbit.settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/previous-selection", forKey: "libraryDirectoryPath")
        let settings = Settings(defaults: defaults)
        XCTAssertThrowsError(try settings.setLibraryDirectory(URL(string: "https://example.invalid/folder")!))
        XCTAssertEqual(defaults.string(forKey: "libraryDirectoryPath"), "/previous-selection")
    }

    #if MAS
    func testInvalidBookmarkFallsBackToContainerAndOffersRenewal() throws {
        let suite = "com.goldenrabbit.bookmark-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/unavailable-external-drive", forKey: "libraryDirectoryPath")
        defaults.set(Data("invalid bookmark".utf8), forKey: "libraryDirectoryBookmark")
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.libraryDirectory, Settings.preferredLibraryDirectory)
        XCTAssertTrue(settings.libraryFolderNeedsRenewal)
        settings.resetLibraryDirectory()
        XCTAssertFalse(settings.libraryFolderNeedsRenewal)
        XCTAssertEqual(settings.libraryDirectory, Settings.preferredLibraryDirectory)
    }
    #endif
}
