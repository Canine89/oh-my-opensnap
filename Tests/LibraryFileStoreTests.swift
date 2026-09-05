import XCTest

final class LibraryFileStoreTests: XCTestCase {
    private var directory: URL!
    private var image: URL { directory.appendingPathComponent("capture.png") }
    private let original = Data("원본".utf8)
    private let annotations = Data("주석".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: image)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testFailedAnnotationWriteRestoresBothFiles() throws {
        let initial = LibraryFileStore()
        try initial.saveAnnotations(annotations, at: image)
        var shouldFail = true
        let store = LibraryFileStore(write: { data, url in
            if url == LibraryFileStore.annotationsURL(for: self.image), shouldFail {
                shouldFail = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertThrowsError(try store.saveEdit(image: Data("크롭".utf8), annotations: Data("새 주석".utf8), at: image))
        let loaded = try initial.load(at: image)
        XCTAssertEqual(loaded.image, original)
        XCTAssertEqual(loaded.annotations, annotations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryFileStore.recoveryURL(for: image).path))
    }

    func testInterruptedRollbackRecoversOnNextOpen() throws {
        try LibraryFileStore().saveAnnotations(annotations, at: image)
        var hasWrittenImage = false
        let failing = LibraryFileStore(write: { data, url in
            if hasWrittenImage { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
            if url == self.image { hasWrittenImage = true }
        })
        XCTAssertThrowsError(try failing.saveEdit(image: Data("크롭".utf8), annotations: Data(), at: image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryFileStore.recoveryURL(for: image).path))
        let loaded = try LibraryFileStore().load(at: image)
        XCTAssertEqual(loaded.image, original)
        XCTAssertEqual(loaded.annotations, annotations)
    }

    func testTrashFailurePreservesImageAndAnnotations() throws {
        let store = LibraryFileStore(moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) })
        try store.saveAnnotations(annotations, at: image)
        XCTAssertThrowsError(try store.trash(at: image))
        let loaded = try store.load(at: image)
        XCTAssertEqual(loaded.image, original)
        XCTAssertEqual(loaded.annotations, annotations)
    }

    func testTrashRestorationRetainsAnnotations() throws {
        let trash = directory.appendingPathComponent("trash.png")
        let store = LibraryFileStore(moveToTrash: { try FileManager.default.moveItem(at: $0, to: trash) })
        try store.saveAnnotations(annotations, at: image)
        try store.trash(at: image)
        try FileManager.default.moveItem(at: trash, to: image)
        XCTAssertEqual(try store.load(at: image).annotations, annotations)
    }

    func testAnnotationsFollowImageDirectoryRatherThanCurrentLibrary() throws {
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherImage = other.appendingPathComponent(image.lastPathComponent)
        try original.write(to: otherImage)
        let store = LibraryFileStore()
        try store.saveAnnotations(annotations, at: image)
        XCTAssertNil(try store.load(at: otherImage).annotations)
        XCTAssertEqual(try store.load(at: image).annotations, annotations)
    }

    func testNewCaptureNeverOverwritesExistingFile() throws {
        XCTAssertThrowsError(try LibraryFileStore().saveNew(Data("새 이미지".utf8), at: image))
        XCTAssertEqual(try Data(contentsOf: image), original)
    }

    func testSuccessfulEditAndAnnotationRemoval() throws {
        let store = LibraryFileStore()
        try store.saveAnnotations(annotations, at: image)
        let edited = Data("크롭".utf8)
        try store.saveEdit(image: edited, annotations: nil, at: image)
        let loaded = try store.load(at: image)
        XCTAssertEqual(loaded.image, edited)
        XCTAssertNil(loaded.annotations)
    }
}
