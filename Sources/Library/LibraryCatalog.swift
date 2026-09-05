import Foundation

struct LibraryItem {
    enum Kind {
        case image
        case animatedImage
        case video
    }

    let url: URL
    let date: Date

    var kind: Kind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v":
            return .video
        case "gif":
            return .animatedImage
        default:
            return .image
        }
    }
}

/// 폴더 메타데이터를 한 번에 읽고 복구 기록이 있는 항목만 복구한다.
/// 메인 스레드 밖에서 호출한다.
enum LibraryCatalog {
    static func load(directory: URL, store: LibraryFileStore = LibraryFileStore()) throws -> [LibraryItem] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let annotations = directory.appendingPathComponent(".annotations", isDirectory: true)
        let recoveryNames = Set(((try? fm.contentsOfDirectory(atPath: annotations.path)) ?? [])
            .filter { $0.hasSuffix(".json.recovery") })
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        var items: [LibraryItem] = []
        for url in urls where ["png", "gif", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            if recoveryNames.contains(url.lastPathComponent + ".json.recovery") { try store.recover(at: url) }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            items.append(LibraryItem(url: url, date: values.creationDate ?? values.contentModificationDate ?? .distantPast))
        }
        return items.sorted {
            $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date
        }
    }
}
