import ShelloModel
import Testing

@testable import ShelloFeatures

@Test(arguments: [
    (Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy"), "deploy@10.0.4.21"),
    (Host(name: "nas", address: "nas.lan", port: 2222, username: ""), "nas.lan:2222"),
    (Host(name: "forge", address: "2001:db8::21", port: 2222, username: "dev"), "dev@[2001:db8::21]:2222"),
    (Host(name: "media-pc", address: "10.0.0.40", protocol: .vnc, username: ""), "10.0.0.40"),
])
func connectionSummaryReadsLikeTheSSHCommandLine(_ host: Host, summary: String) {
    #expect(host.connectionSummary == summary)
}

@Test func hostRowTellsVoiceOverTheProtocolAddressFavoriteAndTags() {
    let host = Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy", isFavorite: true)
    let tags = [Tag(name: "Production", color: .red), Tag(name: "Staging", color: .purple)]

    #expect(
        HostRow.accessibilityValue(of: host, tags: tags)
            == "SSH, deploy at 10.0.4.21, Favorite, Tags: Production, Staging")
}

@Test func hostRowWithoutTagsOrFavoriteTellsVoiceOverOnlyTheConnection() {
    let host = Host(name: "media-pc", address: "10.0.0.40", protocol: .vnc, username: "")

    #expect(HostRow.accessibilityValue(of: host, tags: []) == "VNC, 10.0.0.40")
}

@Test func spokenConnectionSummaryReadsTheUserAndThePortAsWords() {
    let host = Host(name: "prod-api-01", address: "10.0.4.21", port: 2222, username: "deploy")

    #expect(host.spokenConnectionSummary == "deploy at 10.0.4.21, port 2222")
}
