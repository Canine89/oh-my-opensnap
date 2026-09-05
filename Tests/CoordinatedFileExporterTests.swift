import XCTest

final class CoordinatedFileExporterTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCreateAndReplaceAnExplicitlySelectedFile() throws {
        let target = directory.appendingPathComponent("selected.png")
        try CoordinatedFileExporter.write(Data("원본".utf8), to: target)
        try CoordinatedFileExporter.write(Data("새 내용".utf8), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("새 내용".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["selected.png"])
    }

    func testFailedStagingKeepsExistingFileUntouched() throws {
        let target = directory.appendingPathComponent("selected.mp4")
        let original = Data("기존 영상".utf8)
        try original.write(to: target)
        XCTAssertThrowsError(try CoordinatedFileExporter.replace(target) { staging in
            try Data("미완성 영상".utf8).write(to: staging)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testVideoExportReplacesDestinationAndPreservesSource() throws {
        let source = directory.appendingPathComponent("source.mp4")
        let target = directory.appendingPathComponent("destination.mp4")
        let video = Data(repeating: 23, count: 1024 * 1024)
        try video.write(to: source)
        try Data("이전 내보내기".utf8).write(to: target)
        try CoordinatedFileExporter.copy(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: source), video)
        XCTAssertEqual(try Data(contentsOf: target), video)
    }
}
