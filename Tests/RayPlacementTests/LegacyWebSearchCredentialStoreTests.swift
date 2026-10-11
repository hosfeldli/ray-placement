import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func retiredWebSearchCredentialCleanupIsIsolatedAndIdempotent() throws {
    let service = "dev.liam.lima.test.retired-web-\(UUID().uuidString)"
    let store = LegacyWebSearchCredentialStore(service: service, testMode: true)

    #expect(!store.isConfigured)
    try store.remove()
    #expect(!store.isConfigured)
    #expect(LegacyWebSearchCredentialStore.productionService != service)
}
