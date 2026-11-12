import Foundation
import ShelloModel
import ShelloSSH
import Testing

@testable import ShelloCore

/// The plan of an import from an OpenSSH config file and a known_hosts file (README section 3): the
/// hosts with their jump hosts, forwards and SSH keys; hosts Shello has already; routes Shello refuses;
/// the host keys to trust, hashed names matched, one key a server; trusted keys never replaced; and
/// every line left out, with its number and why.
struct OpenSSHImportPlanTests {
    /// Test keys that `ssh-keygen` made (ShelloSSHTests' `KnownHostsTests` has their fingerprints).
    static let ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIJFtpzQWVpf+aJ97q0dxz0/UukN2CIziag3hJj7pN6xi"
    static let p256 =
        "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJcVD/qqXVD8k/bD6p3DsW9/gEYXmgGiRVYo8Wny0WptZE5hFW0VAH4tDU"
        + "mab+IEPduH+gOLeo1UYdM2RRGvJzw="
    /// TestServers/keys/ssh_host_ed25519_key_a.pub.
    static let hostKeyA = "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9"

    static func plan(
        config: String? = nil, knownHosts: String? = nil, saved: [Host] = [], trusted: [Server: TrustedHostKey] = [:],
        sshKeys: [ImportableSSHKey] = []
    ) -> OpenSSHImportPlan {
        OpenSSHImport.plan(
            config: config.map(OpenSSHConfig.init), knownHosts: knownHosts.map(KnownHosts.init), saved: saved,
            trustedKeys: trusted, sshKeys: sshKeys)
    }

    static func key(_ line: String) throws -> HostKey {
        try KnownHostKeys.hostKey(of: try #require(KnownHosts(line).entries.first))
    }

    // MARK: - Hosts

    @Test func eachConcreteNameBecomesAHostWithItsSettings() throws {
        let plan = Self.plan(
            config: """
                Host web web-backup
                    HostName 10.0.1.21
                    User deploy
                Host db
                    Port 2200
                Host *.example.com
                    User nobody
                """)

        #expect(plan.hosts.map(\.host.name) == ["web", "web-backup", "db"])
        let web = plan.hosts[0].host
        #expect(web.address == "10.0.1.21")
        #expect(web.port == 22)
        #expect(web.username == "deploy")
        #expect(web.protocol == .ssh)
        #expect(web.authMethod == .sshKey)
        #expect(web.sshKeyID == nil)
        #expect(plan.hosts[0].origin == .alias(line: 1))
        // Without HostName, the name is the address; without User, there is none.
        let db = plan.hosts[2].host
        #expect(db.address == "db")
        #expect(db.port == 2200)
        #expect(db.username == "")
        // Each host is new.
        #expect(Set(plan.hosts.map(\.id)).count == 3)
        // The pattern block matches no host.
        #expect(
            plan.notImported == [
                .init(file: .config, line: 7, text: "User nobody", reason: "Its Host line matches no host in the file.")
            ])
    }

    @Test func hostNameExpandsPercentH() {
        let plan = Self.plan(config: "Host web db\n  HostName %h.corp.example.com\n")

        #expect(plan.hosts.map(\.host.address) == ["web.corp.example.com", "db.corp.example.com"])
    }

    @Test func hostsWithAnAddressOrPortShelloCannotUseAreListed() {
        let plan = Self.plan(
            config: "Host good\nHost bad-port\n  Port 70000\nHost bad_name!\nHost tokens\n  HostName %d.example.com\n")

        #expect(plan.hosts.map(\.host.name) == ["good"])
        #expect(
            plan.notImported.map(\.line) == [3, 4, 6])
        #expect(plan.notImported[0].reason == "bad-port isn’t imported: its port isn’t a number from 1 to 65535.")
        #expect(
            plan.notImported[1].reason
                == "bad_name! isn’t imported: “bad_name!” isn’t a hostname, an IPv4 address or an IPv6 address. Add a "
                + "HostName for it.")
        #expect(plan.notImported[2].reason == "tokens isn’t imported: its HostName has a % token Shello can’t fill in.")
    }

    @Test func hostThatShelloHasAlreadyIsNotAddedAgain() {
        let saved = Host(name: "Web server", address: "WEB.example.com", username: "deploy")
        let plan = Self.plan(
            config: "Host web\n  HostName web.example.com\n  User deploy\nHost web-root\n  HostName web.example.com\n"
                + "  User root\n",
            saved: [saved])

        #expect(plan.hosts.map(\.host.name) == ["web-root"])
        #expect(plan.existingHosts == [.init(name: "web", line: 1, saved: saved)])
    }

    // MARK: - SSH keys

    @Test func identityFileChoosesTheKeyNamedAfterIt() {
        let work = ImportableSSHKey(id: UUID(), name: "work")
        let plan = Self.plan(
            config: """
                Host a
                    IdentityFile ~/.ssh/missing
                    IdentityFile ~/.ssh/work.pem
                Host b
                    IdentityFile ~/.ssh/id_ed25519
                Host c
                """,
            sshKeys: [ImportableSSHKey(id: UUID(), name: "other"), work])

        #expect(plan.hosts[0].host.sshKeyID == work.id)
        #expect(plan.hosts[0].sshKey == .key(id: work.id, name: "work"))
        #expect(plan.hosts[1].host.sshKeyID == nil)
        #expect(plan.hosts[1].sshKey == .toChoose(fileToImport: "id_ed25519"))
        #expect(plan.hosts[2].sshKey == .toChoose(fileToImport: nil))
        #expect(plan.keyFilesToImport.map(\.file) == ["id_ed25519"])
        #expect(plan.keyFilesToImport.map(\.hosts) == [["b"]])
        // a's first identity file is one no key has, and a signs in with the second.
        #expect(plan.notImported.map(\.line) == [2])
        #expect(plan.notImported.first?.reason.hasPrefix("No host signs in with it") == true)
    }

    // MARK: - Jump hosts

    @Test func proxyJumpThroughAnAliasIsThatHost() throws {
        let plan = Self.plan(
            config: """
                Host bastion
                    HostName bastion.example.com
                    User jump
                Host web
                    HostName 10.0.1.21
                    ProxyJump bastion
                """)

        let bastion = try #require(plan.hosts.first { $0.host.name == "bastion" })
        let web = try #require(plan.hosts.first { $0.host.name == "web" })
        #expect(web.host.jumpHostIDs == [bastion.id])
        #expect(web.jumpHosts == [.init(name: "bastion", isSaved: false)])
        #expect(bastion.host.jumpHostIDs.isEmpty)
    }

    @Test func otherHopsAreHostsOfTheImportHostsInShelloOrNewHosts() throws {
        let saved = Host(name: "Gateway", address: "gw.example.com", port: 2222, username: "ops")
        let plan = Self.plan(
            config: """
                Host bastion
                    HostName bastion.example.com
                    User jump
                Host web
                    ProxyJump ops@gw.example.com:2222,jump@bastion.example.com,ssh://me@new.example.com
                Host *.example.com
                    User fallback
                """,
            saved: [saved])

        let bastion = try #require(plan.hosts.first { $0.host.name == "bastion" })
        let web = try #require(plan.hosts.first { $0.host.name == "web" })
        let new = try #require(plan.hosts.first { $0.host.name == "me@new.example.com" })
        #expect(web.host.jumpHostIDs == [saved.id, bastion.id, new.id])
        #expect(
            web.jumpHosts == [
                .init(name: "Gateway", isSaved: true), .init(name: "bastion", isSaved: false),
                .init(name: "me@new.example.com", isSaved: false),
            ])
        // The new jump host has the hop's user over the file's, and says where it comes from.
        #expect(new.host.address == "new.example.com")
        #expect(new.host.username == "me")
        #expect(new.origin == .jumpHost(of: "web", line: 5))
        #expect(plan.hosts.count == 3)
    }

    @Test func hopWithTheFilesUserAndPortForAnAliasIsThatAlias() throws {
        let plan = Self.plan(
            config: "Host bastion\n  User jump\n  Port 2222\nHost web\n  ProxyJump jump@bastion:2222\n")

        #expect(plan.hosts.count == 2)
        #expect(plan.hosts[1].host.jumpHostIDs == [plan.hosts[0].id])
    }

    @Test func proxyJumpNoneMeansDirect() {
        let plan = Self.plan(config: "Host direct\n  ProxyJump none\nHost *\n  ProxyJump bastion\nHost bastion\n")

        #expect(plan.hosts.first { $0.host.name == "direct" }?.host.jumpHostIDs == [])
    }

    @Test func jumpHostsThatLeadBackAreNotImported() {
        let plan = Self.plan(
            config: """
                Host a
                    ProxyJump b
                Host b
                    ProxyJump a
                Host self
                    ProxyJump self
                Host ok
                """)

        #expect(plan.hosts.map(\.host.name) == ["ok"])
        #expect(plan.notImported.map(\.line) == [2, 4, 6])
        #expect(plan.notImported.allSatisfy { $0.text.hasPrefix("ProxyJump ") })
        #expect(plan.notImported[1].reason == "b isn’t imported: its jump hosts lead back to it through a.")
        #expect(plan.notImported[0].reason == "a isn’t imported: its jump host b isn’t.")
    }

    @Test func routesLongerThanShellosLimitAreNotImported() {
        // h9 jumps through h8, which jumps through h7, and so on: nine jump hosts before h9.
        var lines = ["Host h0"]
        for index in 1...9 {
            lines += ["Host h\(index)", "  ProxyJump h\(index - 1)"]
        }
        lines += ["Host after", "  ProxyJump h9"]
        let plan = Self.plan(config: lines.joined(separator: "\n"))

        #expect(plan.hosts.map(\.host.name) == (0...8).map { "h\($0)" })
        #expect(plan.notImported.map(\.line) == [19, 21])
        #expect(
            plan.notImported.map(\.reason)
                == ["h9", "after"].map { name in
                    "\(name) isn’t imported: its route goes through more than 8 jump hosts, which is Shello’s most."
                })
    }

    @Test func unreadableProxyJumpIsNotImported() {
        let plan = Self.plan(config: "Host a\n  ProxyJump user@\n")

        #expect(plan.hosts.isEmpty)
        #expect(
            plan.notImported == [
                .init(
                    file: .config, line: 2, text: "ProxyJump user@",
                    reason: "a isn’t imported: Shello can’t read its ProxyJump, so it would connect directly.")
            ])
    }

    @Test func hostIsInShelloOnlyWithTheSameJumpHosts() {
        let bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump")
        let inner = Host(name: "inner", address: "10.0.0.5", username: "admin", jumpHostIDs: [bastion.id])
        let plan = Self.plan(
            config: """
                Host bastion
                    HostName bastion.example.com
                    User jump
                Host inner
                    HostName 10.0.0.5
                    User admin
                    ProxyJump bastion
                Host other-side
                    HostName 10.0.0.5
                    User admin
                """,
            saved: [bastion, inner])

        #expect(plan.existingHosts.map(\.saved) == [bastion, inner])
        // The same address behind no jump host is another server.
        #expect(plan.hosts.map(\.host.name) == ["other-side"])
    }

    // MARK: - Forwards

    @Test func forwardsBecomePortForwardsOrSayWhyNot() throws {
        let plan = Self.plan(
            config: """
                Host db
                    LocalForward 5432 localhost:5432
                    LocalForward 127.0.0.1:8080 [fd00::5]:80
                    LocalForward *:8081 web:80
                    LocalForward 0.0.0.0:8082 web:80
                    DynamicForward localhost:1080
                    RemoteForward 9000 localhost:3000
                    RemoteForward *:9001 localhost:3001
                    RemoteForward 10.0.0.1:9002 localhost:3002
                    RemoteForward 0 localhost:3003
                    LocalForward 5432 other:5432
                    LocalForward /tmp/sock localhost:1
                """)

        let forwards = try #require(plan.hosts.first?.host.portForwards)
        #expect(forwards.map(\.port) == [5432, 8080, 1080, 9000, 9001, 9002])
        #expect(forwards.allSatisfy { $0.isEnabled })
        #expect(forwards.allSatisfy { $0.name.isEmpty })
        #expect(forwards[0].kind == .local(destination: ForwardDestination(address: "localhost", port: 5432)))
        #expect(forwards[1].kind == .local(destination: ForwardDestination(address: "fd00::5", port: 80)))
        #expect(forwards[2].kind == .dynamic)
        #expect(
            forwards[3].kind
                == .remote(bindAddress: "", destination: ForwardDestination(address: "localhost", port: 3000)))
        #expect(forwards[4].bindAddress == "*")
        #expect(forwards[5].bindAddress == "10.0.0.1")
        #expect(plan.notImported.map(\.line) == [4, 5, 10, 11, 12])
        #expect(plan.notImported[0].reason.hasPrefix("It listens on every address (*). Shello’s forwards listen on"))
        #expect(plan.notImported[1].reason.hasPrefix("It listens on 0.0.0.0."))
        #expect(plan.notImported[2].reason.hasPrefix("It has the server choose the port."))
        #expect(plan.notImported[3].reason == "For db, port 5432 has a forward already, on line 2.")
        #expect(plan.notImported[4].reason == "It forwards a Unix socket. Shello forwards TCP ports only.")
    }

    // MARK: - Lines left out

    @Test func linesShelloDoesNotImportAreListedWithTheirNumbersInOrder() {
        let plan = Self.plan(
            config: """
                Include ~/.ssh/work
                Host a
                    ForwardAgent yes
                    User first
                Match host a
                    User second
                Host *
                    User default
                """)

        #expect(plan.notImported.map(\.line) == [1, 3, 5, 6, 8])
        #expect(
            plan.notImported.map(\.reason) == [
                "Shello reads only the files you choose, so it doesn’t follow Include. Choose the included file to "
                    + "import it.",
                "Shello doesn’t import ForwardAgent.",
                "Shello doesn’t evaluate Match, so its block applies to no host.",
                "It’s in the Match block on line 5, which Shello doesn’t evaluate.",
                "Every host it applies to takes its User from an earlier line.",
            ])
    }

    // MARK: - Host keys

    @Test func knownHostsKeysAreTrustedForTheirServers() throws {
        let plan = Self.plan(
            knownHosts: """
                github.com,140.82.121.4 ssh-ed25519 \(Self.ed25519)
                [nas.lan]:2222 ecdsa-sha2-nistp256 \(Self.p256)
                @revoked old.example.com ssh-ed25519 \(Self.ed25519)
                """)

        #expect(
            plan.keys.map(\.server) == [
                Server(address: "github.com", port: 22), Server(address: "140.82.121.4", port: 22),
                Server(address: "nas.lan", port: 2222),
            ])
        #expect(plan.keys.map(\.line) == [1, 1, 2])
        let ed25519 = try Self.key("a ssh-ed25519 \(Self.ed25519)")
        #expect(plan.keys[0].key == ed25519)
        #expect(plan.keysToTrust.count == 3)
        #expect(plan.notImported.map(\.line) == [3])
        #expect(plan.notImported.first?.file == .knownHosts)
    }

    /// `ssh-keygen -H` hashed `example.com` and `[code.example.com]:2222` (KnownHostsTests).
    @Test func hashedNamesAreMatchedAgainstSavedAndImportedHosts() {
        let saved = Host(name: "site", address: "Example.com", username: "me")
        let plan = Self.plan(
            config: "Host code\n  HostName code.example.com\n  Port 2222\n",
            knownHosts: """
                |1|3UxmGYwopYVkXqT5fEFyxnSsMJI=|xQfSeaC8J+UDDeMPpuZ58ZzyVPs= ssh-ed25519 \(Self.ed25519)
                |1|p+Ud5V73OBUq0pjA6rr9+PhWYsA=|L6EayKxRXPuifdzAAkKdB4Sz2yg= ecdsa-sha2-nistp256 \(Self.p256)
                |1|AAAAAAAAAAAAAAAAAAAAAAAAAAA=|AAAAAAAAAAAAAAAAAAAAAAAAAAA= ssh-ed25519 \(Self.ed25519)
                """,
            saved: [saved])

        #expect(plan.keys.map(\.server) == [saved.server, Server(address: "code.example.com", port: 2222)])
        #expect(plan.notImported.map(\.line) == [3])
        #expect(
            plan.notImported.first?.reason
                == "Its name is hashed, and is none of the servers of the hosts in Shello or in this import.")
    }

    @Test func oneKeyAServerThePolicysPreferredType() {
        let plan = Self.plan(
            knownHosts: """
                nas.lan ecdsa-sha2-nistp256 \(Self.p256)
                nas.lan ssh-ed25519 \(Self.ed25519)
                nas.lan ssh-ed25519 \(Self.ed25519)
                """)

        #expect(plan.keys.map(\.line) == [2])
        #expect(plan.keys.first?.key.algorithm == "ssh-ed25519")
        // The same key twice adds nothing; the other key is listed.
        #expect(plan.notImported.map(\.line) == [1])
        #expect(
            plan.notImported.first?.reason
                == "Shello trusts one host key a server, and takes the ED25519 key on line 2 for nas.lan:22.")
    }

    @Test func trustedKeyIsKeptAndADifferentOneIsAConflict() throws {
        let trusted = try Self.key("a ssh-ed25519 \(Self.ed25519)")
        let other = try Self.key("a ssh-ed25519 \(Self.hostKeyA)")
        let nas = Server(address: "nas.lan", port: 22)
        let router = Server(address: "router.lan", port: 22)
        let plan = Self.plan(
            knownHosts: """
                nas.lan ssh-ed25519 \(Self.hostKeyA)
                router.lan ssh-ed25519 \(Self.ed25519)
                router.lan ecdsa-sha2-nistp256 \(Self.p256)
                """,
            trusted: [
                nas: TrustedHostKey(key: trusted, trustedAt: .now),
                router: TrustedHostKey(key: trusted, trustedAt: .now),
            ])

        #expect(plan.keys.isEmpty)
        #expect(plan.keysToTrust.isEmpty)
        #expect(plan.conflicts == [.init(server: nas, key: other, line: 1, trusted: trusted)])
        #expect(plan.knownKeys.filter { !$0.isConflict }.map(\.server) == [router])
        #expect(plan.notImported.map(\.line) == [3])
        #expect(plan.addsNothing)
    }

    @Test func plainNamesThatAreNoAddressAreListed() {
        let plan = Self.plan(knownHosts: "bad_name!,ok.example.com ssh-ed25519 \(Self.ed25519)")

        #expect(plan.keys.map(\.server.address) == ["ok.example.com"])
        #expect(plan.notImported.map(\.text) == ["bad_name!"])
    }
}
