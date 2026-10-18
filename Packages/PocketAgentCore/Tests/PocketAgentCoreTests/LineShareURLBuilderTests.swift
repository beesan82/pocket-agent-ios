import Foundation
import Testing
@testable import PocketAgentCore

struct LineShareURLBuilderTests {
    private func decodedText(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "text" }?.value
    }

    @Test func usesOfficialShareEndpoint() throws {
        let url = try LineShareURLBuilder.url(for: "hello")
        #expect(url.absoluteString == "https://line.me/R/share?text=hello")
    }

    @Test(arguments: [
        "10分遅れます🙏",
        "A&B=C+D",
        "1行目\n2行目",
        "100% ok? #tag /path",
    ])
    func roundTripsText(_ text: String) throws {
        let url = try LineShareURLBuilder.url(for: text)
        #expect(decodedText(url) == text)
    }

    @Test func encodesReservedCharacters() throws {
        let query = try LineShareURLBuilder.url(for: "a+b&c=d").query(percentEncoded: true)
        #expect(query == "text=a%2Bb%26c%3Dd")
    }

    @Test(arguments: ["", "   ", "\n"])
    func rejectsEmptyText(_ text: String) {
        #expect(throws: LineShareURLBuilder.BuildError.emptyText) {
            try LineShareURLBuilder.url(for: text)
        }
    }
}
