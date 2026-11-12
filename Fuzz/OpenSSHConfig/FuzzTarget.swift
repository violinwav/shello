// libFuzzer target for the OpenSSH config file that Shello imports hosts from: Packages/ShelloKit/
// Sources/ShelloSSH/OpenSSHFiles/OpenSSHConfig.swift, compiled into one module with this file
// (Fuzz/README.md).
//
// Each input is read as a config file. Nothing may trap; every line number is one of the file's;
// each line is a block, a directive or a skipped line, never a directive and a skipped line; the
// directives keep the file's order and have values; and what each alias and pattern block's names
// resolve to reads as OpenSSH's values: ports from 1 to 65535, ProxyJump hops with a host, and
// forwards with ports from 1 to 65535 and a destination exactly when they are not dynamic.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []
    let config = OpenSSHConfig(bytes: bytes)
    let lineCount = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).count

    let directiveLines = config.directives.map(\.line)
    let skippedLines = config.skipped.map(\.line)
    for line in config.blocks.compactMap(\.line) + directiveLines + skippedLines {
        precondition((1...max(lineCount, 1)).contains(line), "A line number outside the file")
    }
    precondition(directiveLines == directiveLines.sorted(), "Directives out of the file's order")
    precondition(Set(directiveLines).count == directiveLines.count, "A line read as two directives")
    precondition(Set(directiveLines).isDisjoint(with: skippedLines), "A line both read and skipped")
    for directive in config.directives {
        precondition(!directive.arguments.isEmpty, "A directive without a value")
        precondition(
            directive.arguments.count <= (directive.keyword == .localForward || directive.keyword == .remoteForward ? 2 : 1),
            "A directive with more values than it takes")
    }

    // The aliases, and a name each pattern could match, as an import looks them up.
    var names = config.aliases.map(\.name)
    for block in config.blocks {
        names += block.patterns.prefix(4).map { $0.text.filter { $0 != "*" && $0 != "?" } }
    }
    for name in names.prefix(64) {
        let settings = config.settings(for: name)
        for directive in settings.directives {
            precondition(directiveLines.contains(directive.line), "A setting from no directive")
        }
        if let port = settings.port, let number = OpenSSHConfig.port(port.value) {
            precondition(number >= 1, "Port 0")
        }
        if let proxyJump = settings.proxyJump, case .hops(let hops)? = OpenSSHConfig.ProxyJump(proxyJump.value) {
            precondition(!hops.isEmpty, "A ProxyJump without hops")
            for hop in hops {
                precondition(!hop.host.isEmpty, "A hop without a host")
                precondition(hop.port.map { $0 >= 1 } ?? true, "A hop on port 0")
                precondition(hop.user.map { !$0.isEmpty } ?? true, "A hop with an empty user")
            }
        }
        for directive in settings.forwards {
            guard case .success(let forward) = OpenSSHConfig.Forward.parse(directive) else { continue }
            precondition(forward.port >= 1, "A forward on port 0")
            precondition((forward.destination == nil) == (forward.kind == .dynamic), "A destination that does not fit")
            if let destination = forward.destination {
                precondition(!destination.host.isEmpty && destination.port >= 1, "An empty destination")
            }
        }
        _ = OpenSSHConfig.expandingTokens(in: settings.hostName?.value ?? name, ["h": name])
    }
    return 0
}
