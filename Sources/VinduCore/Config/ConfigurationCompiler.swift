import Foundation
import TOMLDecoder

public struct ConfigurationCompiler {
    public static let maximumBytes = 1_048_576

    public init() {}

    public func compile(_ data: Data) -> Result<ConfigurationSnapshot, ConfigurationFailure> {
        guard data.count <= Self.maximumBytes else {
            return failure("configuration is larger than 1048576 bytes")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return failure("configuration is not valid UTF-8")
        }

        let root: [String: Any]
        do {
            root = try Dictionary(TOMLTable(source: text))
        } catch {
            return .failure(ConfigurationFailure([tomlDiagnostic(error)]))
        }

        let keyDiagnostics = ConfigurationKeyValidation.diagnostics(in: root)
        guard keyDiagnostics.isEmpty else {
            return .failure(ConfigurationFailure(keyDiagnostics))
        }
        guard root["schema"] != nil else {
            return failure("missing required key 'schema'", keyPath: "schema")
        }

        let file: ConfigurationFile
        do {
            file = try TOMLDecoder(isLenient: false).decode(ConfigurationFile.self, from: text)
        } catch {
            return .failure(ConfigurationFailure([decodingDiagnostic(error)]))
        }

        do {
            return .success(try ConfigurationSemanticCompiler.compile(file))
        } catch let diagnostic as ConfigurationDiagnosticError {
            return .failure(ConfigurationFailure([diagnostic.diagnostic]))
        } catch {
            return failure("configuration compilation failed: \(error)")
        }
    }

    private func failure(_ message: String, keyPath: String? = nil) -> Result<ConfigurationSnapshot, ConfigurationFailure> {
        .failure(ConfigurationFailure([ConfigurationDiagnostic(keyPath: keyPath, message: message)]))
    }

    private func tomlDiagnostic(_ error: Error) -> ConfigurationDiagnostic {
        let message = String(describing: error)
        return ConfigurationDiagnostic(line: lineNumber(in: message), message: "invalid TOML: \(message)")
    }

    private func decodingDiagnostic(_ error: Error) -> ConfigurationDiagnostic {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                return ConfigurationDiagnostic(keyPath: path(context.codingPath + [key]),
                                               message: "missing required key '\(key.stringValue)'")
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                let description = context.underlyingError.map(String.init(describing:)) ?? context.debugDescription
                return ConfigurationDiagnostic(line: lineNumber(in: description),
                                               keyPath: path(context.codingPath),
                                               message: description)
            @unknown default:
                break
            }
        }
        let message = String(describing: error)
        return ConfigurationDiagnostic(line: lineNumber(in: message), message: message)
    }

    private func path(_ codingPath: [CodingKey]) -> String? {
        let components = codingPath.map { key in
            key.intValue.map { "[\($0)]" } ?? key.stringValue
        }
        guard !components.isEmpty else { return nil }
        return components.reduce(into: "") { result, component in
            result += component.first == "[" ? component : (result.isEmpty ? component : ".\(component)")
        }
    }

    private func lineNumber(in message: String) -> Int? {
        guard let range = message.range(of: #"\(Line ([0-9]+)\)"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(6).dropLast())
    }
}

struct ConfigurationDiagnosticError: Error {
    let diagnostic: ConfigurationDiagnostic
}
