import Testing
@testable import PortlightKit

/// `HostEndpoint.webSocketURL` for every address form a saved connection can hold.
@Suite("Persistence: endpoint URLs")
struct PersistenceEndpointURLTests {
    @Test func ipv4() throws {
        let url = try #require(PersistenceFixtures.endpoint("192.168.1.20").webSocketURL)
        #expect(url.host == "192.168.1.20")
        #expect(url.absoluteString == "wss://192.168.1.20:5920/remote")
        #expect(url.scheme == "wss")
        #expect(url.port == 5920)
        #expect(url.path(percentEncoded: false) == "/remote")
    }

    @Test func hostName() throws {
        let url = try #require(PersistenceFixtures.endpoint("Studio-Mac.local", 5921).webSocketURL)
        #expect(url.host == "Studio-Mac.local")
        #expect(url.absoluteString == "wss://Studio-Mac.local:5921/remote")
    }

    @Test func ipv6IsBracketedInTheURLOnly() throws {
        let plain = try #require(PersistenceFixtures.endpoint("fe80::1").webSocketURL)
        #expect(plain.host == "fe80::1")
        #expect(plain.absoluteString == "wss://[fe80::1]:5920/remote")

        let bracketed = PersistenceFixtures.endpoint("[2001:db8::a:1]", 5921)
        #expect(bracketed.host == "2001:db8::a:1")
        let url = try #require(bracketed.webSocketURL)
        #expect(url.host == "2001:db8::a:1")
        #expect(url.absoluteString == "wss://[2001:db8::a:1]:5921/remote")
        #expect(url.port == 5921)
    }

    @Test func draftAndSavedProfileProduceTheSameURL() throws {
        var form = ConnectionDraft()
        form.host = "[fe80::1]"
        form.port = "5922"
        let fromDraft = try #require(form.endpoint?.webSocketURL)
        let profile = try #require(form.makeProfile(now: PersistenceFixtures.now, id: PersistenceFixtures.id(1)))
        let fromProfile = try #require(profile.endpoint?.webSocketURL)
        #expect(fromDraft == fromProfile)
        #expect(fromProfile.absoluteString == "wss://[fe80::1]:5922/remote")
    }

    @Test func invalidAddressesHaveNoURL() {
        for host in ["wss://studio.local", "studio.local:5920", "fe80::1%en0", ""] {
            #expect(HostEndpoint(host: host, port: 5920)?.webSocketURL == nil)
        }
    }
}
