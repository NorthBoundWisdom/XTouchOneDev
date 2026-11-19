#if os(macOS)
import Foundation
import SurfacePluginContracts
import XTouchOnePanel

struct SavedWorkspace: Codable {
    var version = 1
    var configuration: XTouchOneConfiguration
    var values: [ParameterID: Double]
    var library: [String: XTouchOneConfiguration]
}

struct WorkspaceStore {
    let url: URL

    static var standard: Self {
        let support = URL.applicationSupportDirectory
        return Self(url: support.appending(path: "XTouchOneConsole/workspace.json"))
    }

    func load() throws -> SavedWorkspace? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Self.read(url)
        let document = try JSONDecoder().decode(SavedWorkspace.self, from: data)
        guard document.version == 1 else { throw XTouchOneWorkspaceError.incompatibleConfiguration }
        _ = try XTouchOneWorkspace(configuration: document.configuration, savedValues: document.values)
        for configuration in document.library.values { try configuration.validate() }
        return document
    }

    func save(_ workspace: SavedWorkspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(workspace)
        guard bytes.count <= XTouchOneConfiguration.maximumBytes else { throw XTouchOneWorkspaceError.fileTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
    }

    static func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: XTouchOneConfiguration.maximumBytes + 1) ?? Data()
        guard data.count <= XTouchOneConfiguration.maximumBytes else { throw XTouchOneWorkspaceError.fileTooLarge }
        return data
    }
}
#endif
