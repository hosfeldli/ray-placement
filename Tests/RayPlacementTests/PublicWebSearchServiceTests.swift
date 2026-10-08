import Foundation
import Testing
@testable import RayPlacement

private struct StubPublicSearchBackend: PublicWebSearchBackend {
    enum Outcome {
        case results([PublicWebSearchResult])
        case failure(PublicWebSearchBackendError)
    }

    let outcome: Outcome
    var providerName: String { "Fixture Search" }

    func search(query: String) async throws -> [PublicWebSearchResult] {
        switch outcome {
        case let .results(results): return results
        case let .failure(error): throw error
        }
    }
}

@Test func unconfiguredPublicSearchDoesNotClaimZeroResults() async {
    let response = await PublicWebSearchService().search(query: "pottery near Atlanta")

    #expect(response.status == .providerUnavailable)
    #expect(response.results.isEmpty)
    #expect(response.message?.contains("not a general search service") == true)
}

@Test func publicSearchSeparatesVerifiedZeroResultsFromProviderFailure() async {
    let empty = await PublicWebSearchService(
        backend: StubPublicSearchBackend(outcome: .results([]))
    ).search(query: "no matching place")

    let failed = await PublicWebSearchService(
        backend: StubPublicSearchBackend(outcome: .failure(.requestFailed))
    ).search(query: "nearby pottery")

    #expect(empty.status == .noResults)
    #expect(failed.status == .requestFailed)
    #expect(empty.source == "Fixture Search")
    #expect(failed.source == "Fixture Search")
}

@Test func publicSearchFiltersUnsafeAndOversizedResults() async {
    let valid = PublicWebSearchResult(title: "Studio", url: "https://example.com/studio", snippet: "Clay classes")
    let credentialURL = PublicWebSearchResult(title: "Private", url: "https://user:pass@example.com/", snippet: "not public")
    let localURL = PublicWebSearchResult(title: "Local", url: "file:///etc/passwd", snippet: "not web")
    let tooLarge = PublicWebSearchResult(title: String(repeating: "x", count: 2_049), url: "https://example.com", snippet: "oversized")

    let response = await PublicWebSearchService(
        backend: StubPublicSearchBackend(outcome: .results([valid, credentialURL, localURL, tooLarge]))
    ).search(query: "studio")

    #expect(response.status == .results)
    #expect(response.results == [valid])
}

@Test func publicSearchTrimsAndBoundsTheQuery() async {
    let query = String(repeating: "a", count: 300)
    let response = await PublicWebSearchService().search(query: "  \(query)  ")

    #expect(response.query.count == 256)
    #expect(response.status == .providerUnavailable)
}
