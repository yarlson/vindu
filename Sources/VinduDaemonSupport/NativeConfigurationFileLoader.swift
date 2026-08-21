import Foundation
import VinduCore

public struct NativeConfigurationLoad: Equatable {
    public let path: String
    public let snapshot: ConfigurationSnapshot
    public let wroteDefault: Bool

    public init(path: String, snapshot: ConfigurationSnapshot, wroteDefault: Bool) {
        self.path = path
        self.snapshot = snapshot
        self.wroteDefault = wroteDefault
    }
}

public enum NativeConfigurationSelection: Equatable {
    case loaded(NativeConfigurationLoad)
    case legacyOnly(nativePath: String, legacyPath: String)
}

public enum NativeConfigurationLoadError: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case invalid(path: String, failure: ConfigurationFailure)

    public var description: String {
        switch self {
        case .missing(let path):
            return "configuration does not exist: \(path)"
        case .readFailed(let path, let reason):
            return "cannot read configuration \(path): \(reason)"
        case .writeFailed(let path, let reason):
            return "cannot write default configuration \(path): \(reason)"
        case .invalid(let path, let failure):
            return "invalid configuration \(path): \(failure.diagnostics.map(\.description).joined(separator: "; "))"
        }
    }
}

public struct NativeConfigurationFileLoader {
    public static let maximumBytes = ConfigurationCompiler.maximumBytes

    private let fileManager: FileManager
    private let compiler: ConfigurationCompiler

    public init(fileManager: FileManager = .default,
                compiler: ConfigurationCompiler = ConfigurationCompiler()) {
        self.fileManager = fileManager
        self.compiler = compiler
    }

    public func loadDefault(nativePath: String,
                            legacyPath: String,
                            canonicalDefault: Data) throws -> NativeConfigurationSelection {
        if fileManager.fileExists(atPath: nativePath) {
            return .loaded(try loadExisting(path: nativePath, wroteDefault: false))
        }
        if fileManager.fileExists(atPath: legacyPath) {
            return .legacyOnly(nativePath: nativePath, legacyPath: legacyPath)
        }

        let snapshot = try compile(canonicalDefault, path: nativePath)
        do {
            let directory = (nativePath as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try canonicalDefault.write(to: URL(fileURLWithPath: nativePath), options: .atomic)
        } catch {
            throw NativeConfigurationLoadError.writeFailed(path: nativePath,
                                                           reason: error.localizedDescription)
        }
        return .loaded(NativeConfigurationLoad(path: nativePath,
                                               snapshot: snapshot,
                                               wroteDefault: true))
    }

    public func loadExplicit(path: String) throws -> NativeConfigurationLoad {
        try loadExisting(path: path, wroteDefault: false)
    }

    public func check(path: String) throws -> ConfigurationSnapshot {
        try loadExisting(path: path, wroteDefault: false).snapshot
    }

    private func loadExisting(path: String, wroteDefault: Bool) throws -> NativeConfigurationLoad {
        guard fileManager.fileExists(atPath: path) else {
            throw NativeConfigurationLoadError.missing(path: path)
        }
        let data: Data
        do {
            data = try Self.readBounded(path: path)
        } catch let error as NativeConfigurationLoadError {
            throw error
        } catch {
            throw NativeConfigurationLoadError.readFailed(path: path,
                                                           reason: error.localizedDescription)
        }
        return NativeConfigurationLoad(path: path,
                                       snapshot: try compile(data, path: path),
                                       wroteDefault: wroteDefault)
    }

    private func compile(_ data: Data, path: String) throws -> ConfigurationSnapshot {
        switch compiler.compile(data) {
        case .success(let snapshot):
            return snapshot
        case .failure(let failure):
            throw NativeConfigurationLoadError.invalid(path: path, failure: failure)
        }
    }

    private static func readBounded(path: String) throws -> Data {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }

        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw NativeConfigurationLoadError.readFailed(
                path: path,
                reason: "file exceeds the 1 MiB configuration limit"
            )
        }
        return data
    }
}
