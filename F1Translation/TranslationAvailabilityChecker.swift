import Foundation
import Translation

@available(macOS 15.0, iOS 18.0, *)
public final class TranslationAvailabilityChecker {
    public init() {}
    
    public func checkAvailability(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:
            return true
        default:
            return false
        }
    }
}
