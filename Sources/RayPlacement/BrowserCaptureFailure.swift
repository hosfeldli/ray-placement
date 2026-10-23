import Foundation

/// A failure in protected Browser pixel capture, distinct from semantic page
/// extraction or navigation. The raw value is stable in AI tool results.
enum BrowserCaptureFailure: String, LocalizedError, Sendable {
    case pageUnavailable = "capture_page_unavailable"
    case invalidViewport = "capture_invalid_viewport"
    case navigationChanged = "capture_navigation_changed"
    case redactionUnresolved = "capture_redaction_unresolved"
    case frameUnaccounted = "capture_frame_unaccounted"
    case webKitFailure = "capture_webkit_failure"
    case providerUnsupported = "capture_provider_unsupported"
    case expired = "capture_expired"

    var errorDescription: String? {
        switch self {
        case .pageUnavailable:
            "The Browser page is not ready for a protected visual capture."
        case .invalidViewport:
            "The Browser viewport changed or has invalid capture geometry."
        case .navigationChanged:
            "The Browser navigated or a person interacted during the visual capture."
        case .redactionUnresolved:
            "Lima could not verify masking of protected page content; no pixels were released."
        case .frameUnaccounted:
            "An embedded frame changed or could not be safely accounted for; no pixels were released."
        case .webKitFailure:
            "WebKit could not produce the requested Browser snapshot."
        case .providerUnsupported:
            "The selected AI provider cannot inspect Browser screenshot pixels."
        case .expired:
            "The Browser capture changed or expired before its pixels could be delivered."
        }
    }

    var recoverable: Bool {
        switch self {
        case .redactionUnresolved, .frameUnaccounted, .providerUnsupported:
            false
        default:
            true
        }
    }

    var nextAction: String {
        switch self {
        case .pageUnavailable, .invalidViewport:
            "Check the Browser tab and viewport, then capture a fresh observation."
        case .navigationChanged, .expired:
            "Capture a fresh observation of the current tab; do not reuse old coordinates."
        case .redactionUnresolved, .frameUnaccounted:
            "Use safe semantic content or let the user complete this step in the Browser."
        case .webKitFailure:
            "Inspect Browser navigation diagnostics and retry once after the page is usable."
        case .providerUnsupported:
            "Use a provider that accepts image input or continue with semantic Browser tools."
        }
    }
}
