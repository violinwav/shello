import Foundation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// Secrets never reach the database or the export (README section 13, docs/spec/EXPORT.md). A host
/// saved with a password through the host editor leaves no trace of it in either.
@Suite(.timeLimit(.minutes(1)))
struct SecretsStayOutTests {
    let test: TestDatabase
    let secrets = TestSecrets()
    /// A password that no field, identifier or page of the database holds by chance.
    let password = "Correct-Horse-Battery-7f3a9c"

    init() throws {
        test = try TestDatabase()
    }

    /// Every file SQLite writes, the write-ahead log included, where a new row lives at first.
    @Test func passwordIsInNoFileOfTheDatabase() async throws {
        let host = try await saveHostWithPassword()

        let files = try FileManager.default.contentsOfDirectory(at: test.root, includingPropertiesForKeys: nil)
            .map { try Data(contentsOf: $0) }

        #expect(files.count >= 2)
        // The search works: the host's name is there.
        #expect(files.contains { $0.range(of: Data(host.name.utf8)) != nil })
        #expect(files.allSatisfy { $0.range(of: Data(password.utf8)) == nil })
        #expect(try secrets.password(of: host.id) == password)
    }

    @Test func passwordIsNotInTheExport() async throws {
        let host = try await saveHostWithPassword()

        let data = try await test.exports.export().encoded()

        #expect(data.range(of: Data(password.utf8)) == nil)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(host.id.uuidString))
        #expect(json.contains(#""authMethod" : "password""#))
    }

    private func saveHostWithPassword() async throws -> Host {
        let model = HostEditorModel(repository: test.repository, secrets: secrets.store, host: nil)
        model.draft.name = "vault-01"
        model.draft.address = "vault.lan"
        model.draft.authMethod = .password
        model.password = password
        #expect(await model.save())
        return try #require(try await test.repository.hosts().first)
    }
}
