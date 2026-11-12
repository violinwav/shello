import Foundation
import ShelloModel
import ShelloSSH

/// An SSH key of this device, by name, which an imported host signs in with when its `IdentityFile`
/// has the same name: importing a key from Files names it after its file, without the extension.
public struct ImportableSSHKey: Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Plans the import of hosts from an OpenSSH config file and of trusted host keys from a known_hosts
/// file (README section 3), against the hosts and trusted keys Shello has: `plan(…)`.
///
/// **Hosts.** Every concrete name on a `Host` line becomes a host named after it, with the settings
/// `OpenSSHConfig.settings(for:)` gives it: without `HostName` its address is the name, without
/// `Port` 22, and without `User` it has none. Its `IdentityFile` chooses the SSH key of this device
/// with the file's name; without one, the key is still to choose.
///
/// **Jump hosts.** `ProxyJump`'s hops are the host's jump hosts. A hop that is a name on a `Host` line
/// is that host. Any other is looked up in the file as ssh would, with the hop's user and port over
/// the file's, and is a host of the import with the same server and user, a host in Shello with the
/// same server, user and jump hosts, or a new host named after the hop. A host whose route Shello
/// refuses (`Route`), or whose jump hosts lead back to it, is not imported, nor are the hosts that go
/// through it: Shello never connects to them directly instead.
///
/// **Hosts Shello has.** A host with the server, user and jump hosts of a host in Shello is not added
/// again, and the host in Shello does not change.
///
/// **Forwards.** Each becomes a port forward, on: local and dynamic ones only if they listen on the
/// loopback, which is all Shello listens on (STACK section 7.1); remote ones with their bind address.
/// One that cannot be imported, or that a forward before it has the port of, is left out.
///
/// **Host keys.** Each server named on a line of the known_hosts file gets its key, hashed names
/// matched against the servers of the hosts in Shello and in the import. Shello trusts one key a
/// server: of several, the type its algorithm policy prefers. A server that has a trusted key keeps
/// it: a different key in the file is a conflict, never a replacement.
///
/// Everything left out is in the plan's `notImported`, with its file, line and reason.
public enum OpenSSHImport {
    /// The plan for importing `config` and `knownHosts`, either of which may be missing, into a
    /// Shello with the hosts `saved`, the host keys `trustedKeys` and the SSH keys `sshKeys`.
    public static func plan(
        config: OpenSSHConfig?, knownHosts: KnownHosts?, saved: [Host], trustedKeys: [Server: TrustedHostKey],
        sshKeys: [ImportableSSHKey]
    ) -> OpenSSHImportPlan {
        var planner = Planner(config: config ?? OpenSSHConfig(""), saved: saved, sshKeys: sshKeys)
        if config != nil {
            planner.planHosts()
        }
        if let knownHosts {
            planner.planKeys(knownHosts, trustedKeys: trustedKeys)
        }
        planner.plan.notImported.sort { ($0.file, $0.line) < ($1.file, $1.line) }
        return planner.plan
    }
}

// MARK: - Planner

/// The state of one plan as it is made.
private struct Planner {
    let config: OpenSSHConfig
    let saved: [Host]
    let sshKeys: [ImportableSSHKey]
    var plan = OpenSSHImportPlan()

    /// A host of the config file: a name on a `Host` line, or a hop of a `ProxyJump` that is none.
    struct Entity {
        var name: String
        let origin: OpenSSHImportPlan.Origin
        /// The name the file is looked up with: the alias, or the hop's host.
        let lookupName: String
        var basics: Basics?
        /// Its address, as written.
        var address = ""
        var settings = OpenSSHConfig.Settings()
        /// The entities of its jump hosts, in order.
        var hops: [Int] = []
        /// Why it is not imported, as a line of the file and a reason.
        var failure: (line: Int, text: String, reason: String)?
        /// Its identifier: the saved host's, or a new one.
        var id: Host.ID?
        /// The name of the `IdentityFile` to import, when no key of this device has it.
        var keyFile: String?
        /// The host in Shello it is, if any.
        var savedMatch: Host?
        var host: Host?
    }

    /// What says which server and user a host is.
    struct Basics: Hashable {
        let server: Server
        let user: String
    }

    var entities: [Entity] = []
    var entityByAlias: [String: Int] = [:]
    var entityByBasics: [Basics: Int] = [:]
    /// The config file's lines that a host took a value from.
    var usedLines: Set<Int> = []
    /// The `IdentityFile` lines a new host signs in with or names as the key to import.
    var usedIdentityLines: Set<Int> = []
    /// The `IdentityFile` lines of new hosts.
    var identityLinesOfNewHosts: Set<Int> = []

    init(config: OpenSSHConfig, saved: [Host], sshKeys: [ImportableSSHKey]) {
        self.config = config
        self.saved = saved
        self.sshKeys = sshKeys
    }

    // MARK: Hosts

    mutating func planHosts() {
        for alias in config.aliases {
            let index = addEntity(name: alias.name, origin: .alias(line: alias.line), lookupName: alias.name)
            entityByAlias[alias.name.lowercased()] = index
        }
        var index = 0
        // Jump hosts that are no alias are added as their hops are read.
        while index < entities.count {
            resolveHops(of: index)
            index += 1
        }
        var state = [VisitState](repeating: .unvisited, count: entities.count)
        for index in entities.indices {
            _ = resolveID(of: index, state: &state)
        }
        buildHosts()
        refuseRoutes()
        collectHosts()
        listSkippedConfigLines()
    }

    enum VisitState {
        case unvisited
        case visiting
        case done
    }

    /// Adds the host `name` to the plan's entities, with what the file says for `lookupName`, the hop's
    /// `user` and `port` over the file's.
    mutating func addEntity(
        name: String, origin: OpenSSHImportPlan.Origin, lookupName: String, user: String? = nil, port: UInt16? = nil
    ) -> Int {
        var entity = Entity(name: name, origin: origin, lookupName: lookupName)
        entity.settings = config.settings(for: lookupName)
        usedLines.formUnion(entity.settings.directives.map(\.line))
        switch basics(of: lookupName, settings: entity.settings, user: user, port: port) {
        case .success(let found):
            entity.basics = found.basics
            entity.address = found.address
        case .failure(let failure):
            entity.failure = (failure.line, failure.text, failure.reason)
        }
        entities.append(entity)
        let index = entities.count - 1
        if let basics = entity.basics, entityByBasics[basics] == nil {
            entityByBasics[basics] = index
        }
        return index
    }

    /// The server and user of the host `name`, from `settings`, with `user` and `port` over theirs.
    func basics(
        of name: String, settings: OpenSSHConfig.Settings, user: String?, port: UInt16?
    ) -> Result<(basics: Basics, address: String), FailureBox> {
        var address = name
        if let hostName = settings.hostName {
            guard let expanded = OpenSSHConfig.expandingTokens(in: hostName.value, ["h": name]) else {
                return .failure(
                    FailureBox(
                        hostName.line, Self.text(of: hostName),
                        "\(name) isn’t imported: its HostName has a % token Shello can’t fill in."))
            }
            address = expanded
        }
        guard !address.unicodeScalars.contains("\0"), AddressKind(of: address) != nil else {
            let line = settings.hostName.map(\.line) ?? aliasLine(of: name)
            let text = settings.hostName.map(Self.text(of:)) ?? name
            let fix = settings.hostName == nil ? " Add a HostName for it." : ""
            return .failure(
                FailureBox(
                    line, text,
                    "\(name) isn’t imported: “\(address)” isn’t a hostname, an IPv4 address or an IPv6 address.\(fix)"))
        }
        var number = KnownHosts.defaultPort
        if let port {
            number = port
        } else if let directive = settings.port {
            guard let parsed = OpenSSHConfig.port(directive.value) else {
                return .failure(
                    FailureBox(
                        directive.line, Self.text(of: directive),
                        "\(name) isn’t imported: its port isn’t a number from 1 to 65535."))
            }
            number = parsed
        }
        let userName = user ?? settings.user?.value ?? ""
        guard !userName.unicodeScalars.contains("\0") else {
            return .failure(
                FailureBox(
                    settings.user?.line ?? aliasLine(of: name), name,
                    "\(name) isn’t imported: its user has a null character."))
        }
        return .success((Basics(server: Server(address: address, port: number), user: userName), address))
    }

    /// The line of the `Host` that names `name`, or 0.
    func aliasLine(of name: String) -> Int {
        config.aliases.first { $0.name.lowercased() == name.lowercased() }?.line ?? 0
    }

    /// Reads the `ProxyJump` of the entity `index`, and finds or adds the entity of each hop.
    mutating func resolveHops(of index: Int) {
        guard entities[index].failure == nil, let directive = entities[index].settings.proxyJump,
            let basics = entities[index].basics
        else { return }
        let name = entities[index].name
        let tokens: [Character: String] = [
            "h": entities[index].address, "n": entities[index].lookupName, "p": String(basics.server.port),
            "r": basics.user,
        ]
        guard let text = OpenSSHConfig.expandingTokens(in: directive.value, tokens),
            let proxyJump = OpenSSHConfig.ProxyJump(text)
        else {
            entities[index].failure = (
                directive.line, Self.text(of: directive),
                "\(name) isn’t imported: Shello can’t read its ProxyJump, so it would connect directly."
            )
            return
        }
        guard case .hops(let hops) = proxyJump else { return }
        var indexes: [Int] = []
        for hop in hops {
            if hop.user == nil, hop.port == nil, let alias = entityByAlias[hop.host.lowercased()] {
                indexes.append(alias)
                continue
            }
            let settings = config.settings(for: hop.host)
            switch self.basics(of: hop.host, settings: settings, user: hop.user, port: hop.port) {
            case .failure(let failure):
                entities[index].failure = (
                    directive.line, Self.text(of: directive),
                    "\(name) isn’t imported: its jump host \(hop.text) can’t be. \(failure.reason)"
                )
                return
            case .success(let found):
                let hopBasics = found.basics
                if let alias = entityByAlias[hop.host.lowercased()], entities[alias].basics == hopBasics {
                    indexes.append(alias)
                } else if let known = entityByBasics[hopBasics] {
                    indexes.append(known)
                } else {
                    indexes.append(
                        addEntity(
                            name: hop.text, origin: .jumpHost(of: name, line: directive.line), lookupName: hop.host,
                            user: hop.user, port: hop.port))
                }
            }
        }
        entities[index].hops = indexes
    }

    /// The identifier of the entity `index`: that of the host in Shello with its server, user and
    /// jump hosts, or a new one; nil if it is not imported, or its jump hosts lead back to it.
    mutating func resolveID(of index: Int, state: inout [VisitState]) -> Host.ID? {
        switch state[index] {
        case .done: return entities[index].id
        case .visiting: return nil
        case .unvisited: break
        }
        state[index] = .visiting
        defer { state[index] = .done }
        guard entities[index].failure == nil, let basics = entities[index].basics else { return nil }
        var jumpHostIDs: [Host.ID] = []
        for hop in entities[index].hops {
            guard let id = resolveID(of: hop, state: &state) else {
                let line = entities[index].settings.proxyJump?.line ?? 0
                let text = entities[index].settings.proxyJump.map(Self.text(of:)) ?? ""
                let name = entities[index].name
                let reason =
                    state[hop] == .visiting
                    ? "\(name) isn’t imported: its jump hosts lead back to it through \(entities[hop].name)."
                    : "\(name) isn’t imported: its jump host \(entities[hop].name) isn’t."
                entities[index].failure = (line, text, reason)
                return nil
            }
            jumpHostIDs.append(id)
        }
        if let match = saved.first(where: {
            $0.server == basics.server && $0.username == basics.user && $0.jumpHostIDs == jumpHostIDs
        }) {
            entities[index].savedMatch = match
            entities[index].id = match.id
        } else {
            entities[index].id = UUID()
        }
        entities[index].host = Host(
            id: entities[index].id ?? UUID(), name: entities[index].name, address: entities[index].address,
            port: basics.server.port, username: basics.user, jumpHostIDs: jumpHostIDs)
        return entities[index].id
    }

    /// Gives each new host its SSH key and its forwards.
    mutating func buildHosts() {
        for index in entities.indices where entities[index].savedMatch == nil {
            guard var host = entities[index].host, entities[index].failure == nil else { continue }
            identityLinesOfNewHosts.formUnion(entities[index].settings.identityFiles.map(\.line))
            host.sshKeyID = sshKey(of: index)
            host.portForwards = forwards(of: index)
            entities[index].host = host
        }
    }

    /// The SSH key of the entity `index`: that of the first `IdentityFile` a key of this device is named
    /// after, or none, keeping the first `IdentityFile` as the one to import.
    mutating func sshKey(of index: Int) -> UUID? {
        let entity = entities[index]
        guard let basics = entity.basics else { return nil }
        let tokens: [Character: String] = [
            "h": entity.address, "n": entity.lookupName, "p": String(basics.server.port), "r": basics.user,
        ]
        var firstFile: (line: Int, name: String)?
        for directive in entity.settings.identityFiles where directive.value.lowercased() != "none" {
            let written = directive.value.split(separator: "/").last.map(String.init) ?? directive.value
            guard let file = OpenSSHConfig.expandingTokens(in: written, tokens), !file.isEmpty else { continue }
            let name = Self.keyName(ofFile: file)
            if let key = sshKeys.first(where: { $0.name == name }) {
                usedIdentityLines.insert(directive.line)
                return key.id
            }
            if firstFile == nil {
                firstFile = (directive.line, file)
            }
        }
        if let firstFile {
            usedIdentityLines.insert(firstFile.line)
            entities[index].keyFile = firstFile.name
        }
        return nil
    }

    /// The name Shello gives a key imported from the file `file`: its name without the extension.
    static func keyName(ofFile file: String) -> String {
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
        return String(file[..<dot])
    }

    /// The forwards of the entity `index` that Shello can import, each on; the others are listed.
    mutating func forwards(of index: Int) -> [PortForward] {
        let name = entities[index].name
        var forwards: [PortForward] = []
        var lines: [UInt16: Int] = [:]
        var serverLines: [UInt16: Int] = [:]
        for directive in entities[index].settings.forwards {
            let forward: PortForward
            switch OpenSSHConfig.Forward.parse(directive) {
            case .failure(let problem):
                leaveOut(directive, Self.reason(for: problem))
                continue
            case .success(let parsed):
                switch Self.portForward(parsed) {
                case .failure(let failure):
                    leaveOut(directive, failure.reason)
                    continue
                case .success(let converted):
                    forward = converted
                }
            }
            if let problem = forward.problems.first {
                leaveOut(directive, problem)
                continue
            }
            if forward.isRemote {
                if let first = serverLines[forward.port] {
                    leaveOut(
                        directive,
                        "For \(name), the server’s port \(forward.port) has a remote forward already, on line \(first)."
                    )
                    continue
                }
                serverLines[forward.port] = directive.line
            } else {
                if let first = lines[forward.port] {
                    leaveOut(directive, "For \(name), port \(forward.port) has a forward already, on line \(first).")
                    continue
                }
                lines[forward.port] = directive.line
            }
            forwards.append(forward)
        }
        return forwards
    }

    /// A forward of the config file as a port forward, or why Shello cannot import it.
    static func portForward(_ forward: OpenSSHConfig.Forward) -> Result<PortForward, ReasonBox> {
        let destination = forward.destination.map { ForwardDestination(address: $0.host, port: $0.port) }
        switch forward.kind {
        case .local, .dynamic:
            if let bind = forward.bindAddress, !["localhost", "127.0.0.1"].contains(bind.lowercased()) {
                let address = bind.isEmpty ? "every address" : bind == "*" ? "every address (*)" : bind
                return .failure(
                    ReasonBox(
                        "It listens on \(address). Shello’s forwards listen on 127.0.0.1 only, which other apps on "
                            + "this device can reach, never the network."))
            }
            if forward.kind == .dynamic {
                return .success(PortForward(port: forward.port, kind: .dynamic))
            }
            guard let destination else { return .failure(ReasonBox("It has no destination.")) }
            return .success(PortForward(port: forward.port, kind: .local(destination: destination)))
        case .remote:
            guard let destination else { return .failure(ReasonBox("It has no destination.")) }
            let bind: String
            switch forward.bindAddress?.lowercased() {
            case nil, "localhost": bind = ""
            case "", "*": bind = PortForward.allAddresses
            default: bind = forward.bindAddress ?? ""
            }
            return .success(PortForward(port: forward.port, kind: .remote(bindAddress: bind, destination: destination)))
        }
    }

    static func reason(for problem: OpenSSHConfig.Forward.Problem) -> String {
        switch problem {
        case .unixSocket:
            "It forwards a Unix socket. Shello forwards TCP ports only."
        case .serverChosenPort:
            "It has the server choose the port. Shello always names the port: enter one from 1 to 65535."
        case .reverseDynamic:
            "It’s a remote dynamic (SOCKS) forward, which Shello doesn’t have."
        case .environmentVariable:
            "It uses an environment variable of your computer’s, which Shello can’t know."
        case .malformed:
            "Shello can’t read it as a forward: its ports must be numbers from 1 to 65535, and a local or remote "
                + "forward needs a destination."
        }
    }

    /// Leaves the line of `directive` out, with `reason`.
    mutating func leaveOut(_ directive: OpenSSHConfig.Directive, _ reason: String) {
        add(.config, directive.line, Self.text(of: directive), reason)
    }

    mutating func add(_ file: OpenSSHImportPlan.File, _ line: Int, _ text: String, _ reason: String) {
        let item = OpenSSHImportPlan.NotImported(file: file, line: line, text: text, reason: reason)
        // A line of a block that applies to several hosts is listed once for each reason.
        if !plan.notImported.contains(item) {
            plan.notImported.append(item)
        }
    }

    /// Leaves out every new host whose route Shello refuses, and every host that goes through one,
    /// until no route is refused.
    mutating func refuseRoutes() {
        var changed = true
        while changed {
            changed = false
            var hosts = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for entity in entities where entity.failure == nil && entity.savedMatch == nil {
                if let host = entity.host { hosts[host.id] = host }
            }
            for index in entities.indices where entities[index].failure == nil && entities[index].savedMatch == nil {
                guard let host = entities[index].host else { continue }
                do {
                    _ = try Route(to: host, hosts: hosts)
                } catch {
                    let directive = entities[index].settings.proxyJump
                    entities[index].failure = (
                        directive?.line ?? entities[index].origin.line,
                        directive.map(Self.text(of:)) ?? host.name, Self.reason(for: error, of: host.name)
                    )
                    changed = true
                }
            }
        }
    }

    static func reason(for error: RouteError, of name: String) -> String {
        switch error {
        case .missingJumpHost:
            "\(name) isn’t imported: one of its jump hosts isn’t."
        case .repeatsHost(let hop):
            "\(name) isn’t imported: its route goes through \(hop) twice, which Shello doesn’t allow."
        case .tooManyJumpHosts:
            "\(name) isn’t imported: its route goes through more than \(Route.maximumJumpHosts) jump hosts, "
                + "which is Shello’s most."
        case .notSSH(let hop):
            "\(name) isn’t imported: \(hop) isn’t an SSH host, so it can’t be a jump host."
        }
    }

    /// Puts the new hosts, the hosts in Shello and those not imported into the plan.
    mutating func collectHosts() {
        for index in entities.indices {
            let entity = entities[index]
            if let failure = entity.failure {
                add(.config, failure.line, failure.text, failure.reason)
                continue
            }
            if let saved = entity.savedMatch {
                if case .alias(let line) = entity.origin {
                    plan.existingHosts.append(
                        OpenSSHImportPlan.ExistingHost(name: entity.name, line: line, saved: saved))
                }
                continue
            }
            guard let host = entity.host else { continue }
            let jumpHosts = entity.hops.map { hop in
                OpenSSHImportPlan.JumpHost(
                    name: entities[hop].savedMatch?.name ?? entities[hop].name, isSaved: entities[hop].savedMatch != nil
                )
            }
            let choice: OpenSSHImportPlan.SSHKeyChoice =
                if let id = host.sshKeyID, let key = sshKeys.first(where: { $0.id == id }) {
                    .key(id: id, name: key.name)
                } else {
                    .toChoose(fileToImport: entity.keyFile)
                }
            plan.hosts.append(
                OpenSSHImportPlan.NewHost(host: host, origin: entity.origin, jumpHosts: jumpHosts, sshKey: choice))
        }
    }

    /// Lists the config file's skipped lines, and the lines of directives no imported host uses.
    mutating func listSkippedConfigLines() {
        for skipped in config.skipped {
            add(.config, skipped.line, skipped.text, Self.reason(for: skipped.reason))
        }
        let names = entities.map(\.lookupName)
        for block in config.blocks {
            for directive in block.directives {
                if !usedLines.contains(directive.line) {
                    let reason =
                        names.contains(where: block.matches)
                        ? "Every host it applies to takes its \(directive.keyword.name) from an earlier line."
                        : "Its Host line matches no host in the file."
                    leaveOut(directive, reason)
                } else if directive.keyword == .identityFile, identityLinesOfNewHosts.contains(directive.line),
                    !usedIdentityLines.contains(directive.line)
                {
                    leaveOut(
                        directive,
                        "No host signs in with it: Shello signs in to a host with one SSH key, from the first "
                            + "IdentityFile it has a key for.")
                }
            }
        }
    }

    static func reason(for reason: OpenSSHConfig.SkippedLine.Reason) -> String {
        switch reason {
        case .unsupported(let keyword):
            "Shello doesn’t import \(keyword)."
        case .include:
            "Shello reads only the files you choose, so it doesn’t follow Include. Choose the included file to "
                + "import it."
        case .match:
            "Shello doesn’t evaluate Match, so its block applies to no host."
        case .inMatchBlock(let line):
            "It’s in the Match block on line \(line), which Shello doesn’t evaluate."
        case .missingValue(let keyword?):
            "Its \(keyword.name) has no value."
        case .missingValue(nil):
            "It has a keyword without a value."
        case .extraValues(let keyword):
            "Its \(keyword.name) has more values than it takes."
        case .unclosedQuote:
            "A quote on it isn’t closed."
        case .nullCharacter:
            "It has a null character."
        }
    }

    /// The directive as a line of the file, its arguments in quotes where they have spaces.
    static func text(of directive: OpenSSHConfig.Directive) -> String {
        ([directive.keyword.name]
            + directive.arguments.map { argument in
                argument.contains(where: \.isWhitespace) || argument.isEmpty ? "\"\(argument)\"" : argument
            })
            .joined(separator: " ")
    }

    // MARK: Host keys

    mutating func planKeys(_ file: KnownHosts, trustedKeys: [Server: TrustedHostKey]) {
        for skipped in file.skipped {
            add(.knownHosts, skipped.line, skipped.text, Self.reason(for: skipped.reason))
        }
        // The servers a hashed name can be: those of the hosts in Shello and of the new ones.
        var candidates: [Server] = []
        var seenCandidates: Set<Server> = []
        for server in saved.map(\.server) + plan.hosts.map(\.host.server) where seenCandidates.insert(server).inserted {
            candidates.append(server)
        }
        var servers: [Server] = []
        var keysByServer: [Server: [(key: HostKey, line: Int)]] = [:]
        for entry in file.entries {
            let key: HostKey
            do {
                key = try KnownHostKeys.hostKey(of: entry)
            } catch {
                add(.knownHosts, entry.line, entry.keyBase64, "Its key can’t be read.")
                continue
            }
            var entryServers: [Server] = []
            for name in entry.names {
                switch name {
                case .plain(let host, let port):
                    guard AddressKind(of: host) != nil else {
                        add(
                            .knownHosts, entry.line, KnownHosts.Name.written(host: host, port: port),
                            "It isn’t a hostname, an IPv4 address or an IPv6 address.")
                        continue
                    }
                    entryServers.append(Server(address: host, port: port))
                case .hashed:
                    let matches = candidates.filter { server in
                        name.matches(host: server.address, port: server.port, hmacSHA1: KnownHostKeys.hmacSHA1)
                    }
                    if matches.isEmpty {
                        add(
                            .knownHosts, entry.line, "Hashed name",
                            "Its name is hashed, and is none of the servers of the hosts in Shello or in this import.")
                    }
                    entryServers += matches
                }
            }
            for server in entryServers {
                if keysByServer[server] == nil {
                    servers.append(server)
                }
                // The same key on another line adds nothing.
                if keysByServer[server, default: []].contains(where: { $0.key == key }) { continue }
                keysByServer[server, default: []].append((key, entry.line))
            }
        }
        for server in servers {
            let keys = keysByServer[server] ?? []
            if let trusted = trustedKeys[server]?.key {
                if let same = keys.first(where: { $0.key == trusted }) {
                    plan.knownKeys.append(
                        OpenSSHImportPlan.KnownKey(server: server, key: same.key, line: same.line, trusted: trusted))
                    for other in keys where other.line != same.line {
                        add(
                            .knownHosts, other.line, "\(other.key.typeName) key for \(server)",
                            "Shello trusts one host key a server, and trusts the \(trusted.typeName) key on line "
                                + "\(same.line) for \(server) already.")
                    }
                } else {
                    for (key, line) in keys {
                        plan.knownKeys.append(
                            OpenSSHImportPlan.KnownKey(server: server, key: key, line: line, trusted: trusted))
                    }
                }
                continue
            }
            let ordered = keys.enumerated().sorted { first, second in
                (Self.preference(of: first.element.key), first.offset)
                    < (Self.preference(of: second.element.key), second.offset)
            }.map(\.element)
            guard let chosen = ordered.first else { continue }
            plan.keys.append(OpenSSHImportPlan.NewKey(server: server, key: chosen.key, line: chosen.line))
            for other in ordered.dropFirst() {
                add(
                    .knownHosts, other.line, "\(other.key.typeName) key for \(server)",
                    "Shello trusts one host key a server, and takes the \(chosen.key.typeName) key on line "
                        + "\(chosen.line) for \(server).")
            }
        }
    }

    /// Where the key's type comes in Shello's preference, the algorithm policy's.
    static func preference(of key: HostKey) -> Int {
        KnownHosts.supportedKeyTypes.firstIndex(of: key.algorithm) ?? KnownHosts.supportedKeyTypes.count
    }

    static func reason(for reason: KnownHosts.SkippedLine.Reason) -> String {
        switch reason {
        case .marker("@cert-authority"):
            "Shello trusts host keys, not certificate authorities."
        case .marker("@revoked"):
            "Shello doesn’t import revoked keys. It never trusts a key you haven’t accepted or imported."
        case .marker(let marker):
            "Shello doesn’t know the marker \(marker)."
        case .wildcard:
            "A name with * or ? stands for many servers. Shello trusts a key for one server at a time."
        case .negated:
            "Shello doesn’t import names with !."
        case .malformedName:
            "Shello can’t read it as a host, [host]:port, or a hashed name."
        case .unsupportedKeyType(let type):
            "Shello doesn’t trust \(type) host keys."
        case .malformedKey:
            "Its key isn’t a key of its type."
        case .malformed:
            "It doesn’t have names, a key type and a key."
        case .nullCharacter:
            "It has a null character."
        }
    }
}

/// A failure of a host, as a value `Result` can carry.
private struct FailureBox: Error {
    let line: Int
    let text: String
    let reason: String

    init(_ line: Int, _ text: String, _ reason: String) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}

/// A reason a forward is left out, as a value `Result` can carry.
private struct ReasonBox: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}

extension OpenSSHImportPlan.Origin {
    fileprivate var line: Int {
        switch self {
        case .alias(let line), .jumpHost(_, let line): line
        }
    }
}
