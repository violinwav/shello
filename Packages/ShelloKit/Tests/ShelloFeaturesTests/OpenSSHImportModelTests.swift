import Foundation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// The import from OpenSSH's files in Settings (README section 3): files read as the file importer
/// hands them over, the preview, the import and its summary, which keeps the lines left out; and a
/// host key trusted while the preview showed, which the import keeps.
@Suite(.timeLimit(.minutes(1)))
struct OpenSSHImportModelTests {
    let test: TestDatabase
    let keys: TestKeys
    let model: OpenSSHImportModel

    /// A test key that `ssh-keygen` made, and another, TestServers' host key a.
    static let ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIJFtpzQWVpf+aJ97q0dxz0/UukN2CIziag3hJj7pN6xi"
    static let hostKeyA = "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9"

    static let config = """
        Host bastion
            HostName bastion.example.com
            User jump
        Host web
            HostName 10.0.1.21
            ProxyJump bastion
            IdentityFile ~/.ssh/deploy
            LocalForward 8080 localhost:80
            ForwardAgent yes
        """

    static let knownHosts = """
        bastion.example.com ssh-ed25519 \(ed25519)
        @cert-authority *.example.com ssh-ed25519 \(ed25519)
        """

    init() throws {
        test = try TestDatabase()
        keys = TestKeys()
        model = OpenSSHImportModel(repository: test.hostImports, sshKeys: keys.store)
    }

    /// Writes `text` to a file named `name`, as the file importer would hand it over.
    private func file(_ name: String, _ text: String) throws -> URL {
        let folder = test.root.deletingLastPathComponent().appending(path: "OpenSSH-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func previewShowsWhatTheFilesAdd() async throws {
        let deploy = try await keys.make("deploy")

        await model.fileChosen(.config, .success(try file("config", Self.config)))

        #expect(model.configFile == .init(name: "config", lineCount: 9))
        let plan = try #require(model.plan)
        #expect(plan.hosts.map(\.host.name) == ["bastion", "web"])
        #expect(plan.hosts[1].host.sshKeyID == deploy.id)
        #expect(plan.notImported.map(\.line) == [9])
        #expect(model.canImport)
        #expect(
            OpenSSHImportDisplay.overview(plan) == "Import adds 2 hosts. 1 line isn’t imported, as listed below.")

        await model.fileChosen(.knownHosts, .success(try file("known_hosts", Self.knownHosts)))

        #expect(model.knownHostsFile == .init(name: "known_hosts", lineCount: 2))
        let withKeys = try #require(model.plan)
        #expect(withKeys.keys.map(\.server) == [Server(address: "bastion.example.com", port: 22)])
        #expect(
            OpenSSHImportDisplay.overview(withKeys)
                == "Import adds 2 hosts and trusts 1 host key. 2 lines aren’t imported, as listed below.")
        // Nothing is stored before Import.
        #expect(try await test.repository.hosts().isEmpty)
    }

    @Test func importStoresThePlanAndKeepsTheLinesLeftOut() async throws {
        await model.fileChosen(.config, .success(try file("config", Self.config)))
        await model.fileChosen(.knownHosts, .success(try file("known_hosts", Self.knownHosts)))

        await model.importPlan()

        let summary = try #require(model.summary)
        #expect(summary.status == "Added 2 hosts and trusted 1 host key.")
        #expect(summary.notImported.map(\.file) == [.config, .knownHosts])
        #expect(summary.notImported.map(\.line) == [9, 2])
        #expect(summary.keyFiles == [.init(file: "deploy", hosts: ["web"])])
        #expect(!model.canImport)
        let hosts = try await test.repository.hosts()
        #expect(hosts.map(\.name) == ["bastion", "web"])
        let bastion = try #require(hosts.first { $0.name == "bastion" })
        #expect(hosts.first { $0.name == "web" }?.jumpHostIDs == [bastion.id])
        #expect(try await test.hostKeys.trustedKey(of: bastion.server) != nil)
    }

    /// A key trusted for the server while the preview showed is kept, and the summary lists the
    /// import's key as one that differs.
    @Test func keyTrustedWhileThePreviewShowedIsKept() async throws {
        await model.fileChosen(.knownHosts, .success(try file("known_hosts", Self.knownHosts)))
        let server = Server(address: "bastion.example.com", port: 22)
        let other = HostKey(
            algorithm: "ssh-ed25519", wireRepresentation: try #require(Data(base64Encoded: Self.hostKeyA)),
            fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")
        try await test.hostKeys.trust(other, of: server)

        await model.importPlan()

        #expect(try await test.hostKeys.trustedKey(of: server)?.key == other)
        let summary = try #require(model.summary)
        #expect(summary.keys.isEmpty)
        #expect(summary.conflicts.map(\.server) == [server])
        #expect(summary.conflicts.first?.trusted == other)
        #expect(summary.status == "Imported nothing.")
    }

    @Test func removingAFilePlansWithoutIt() async throws {
        await model.fileChosen(.config, .success(try file("config", Self.config)))
        await model.fileChosen(.knownHosts, .success(try file("known_hosts", Self.knownHosts)))

        await model.remove(.config)

        #expect(model.configFile == nil)
        #expect(model.plan?.hosts.isEmpty == true)
        #expect(model.plan?.keys.count == 1)
        await model.remove(.knownHosts)
        #expect(model.plan == nil)
        #expect(!model.canImport)
    }

    @Test func fileThatCannotBeReadSaysSo() async throws {
        let missing = test.root.appending(path: "missing-config")

        await model.fileChosen(.config, .success(missing))

        #expect(model.problem?.hasPrefix("Shello couldn’t read “missing-config”.") == true)
        #expect(model.configFile == nil)
        #expect(model.plan == nil)
    }

    @Test func choosingAFileKeepsItsKindPastTheImportersDismissal() {
        model.choose(.knownHosts)
        #expect(model.isPicking)
        // The importer sets this back before it hands over the file.
        model.isPicking = false
        #expect(model.pickedKind == .knownHosts)
    }

    // MARK: - What VoiceOver hears

    @Test func newHostReadsAsOneElement() throws {
        let plan = OpenSSHImport.plan(
            config: OpenSSHConfig(
                "Host bastion\n  User jump\nHost web\n  HostName fd00::5\n  ProxyJump bastion\n  DynamicForward 1080\n"
                    + "  IdentityFile ~/.ssh/id_ed25519\n"),
            knownHosts: nil, saved: [], trustedKeys: [:], sshKeys: [])
        let web = try #require(plan.hosts.last)

        #expect(
            OpenSSHImportDisplay.details(web).map(\.text) == [
                "[fd00::5]:22, no user", "Through bastion", "SOCKS5 on 1080",
                "SSH key to choose: import “id_ed25519” first",
                "Enter a user before connecting", "Line 3",
            ])
        #expect(OpenSSHImportDisplay.details(web).map(\.needsAttention) == [false, false, false, true, true, false])
        // What it still needs comes first.
        #expect(
            OpenSSHImportDisplay.spokenDetails(web)
                == "Needs a user and an SSH key. fd00::5, port 22, no user. Through bastion. Dynamic forward, SOCKS5 "
                + "on port 1080. SSH key to choose: import “id_ed25519” first. Line 3")
        let bastion = try #require(plan.hosts.first)
        #expect(OpenSSHImportDisplay.spokenDetails(bastion).hasPrefix("Needs an SSH key. jump at bastion, port 22."))
    }

    @Test func importIsDimmedWithAReason() async throws {
        #expect(!model.canImport)
        await model.fileChosen(.knownHosts, .success(try file("known_hosts", "# nothing\n")))
        #expect(model.plan?.addsNothing == true)
        #expect(!model.canImport)
        #expect(OpenSSHImportDisplay.overview(try #require(model.plan)) == "There’s nothing new to import.")
    }
}
