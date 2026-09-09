import Foundation
import GooglePlaces

@MainActor
final class GooglePlacesAutocomplete: LocationSuggesting {
  // Each target initializes its own SDK process using its bundle's restricted key.
  private static let configured: Bool = {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "GooglePlacesAPIKey") as? String else {
      return false
    }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("$(") else { return false }
    return GMSPlacesClient.provideAPIKey(trimmed)
  }()

  var isConfigured: Bool { Self.configured }

  func suggestions(for query: String) async throws -> [LocationSuggestion] {
    guard isConfigured else { return [] }
    let request = GMSAutocompleteRequest(query: query)
    // Only autocomplete text is needed. No Place Details request or session token:
    // Google bills these as individual autocomplete requests. Debouncing limits calls.
    return try await withCheckedThrowingContinuation { continuation in
      GMSPlacesClient.shared().fetchAutocompleteSuggestions(from: request) { results, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let suggestions = (results ?? []).compactMap { result -> LocationSuggestion? in
          guard let place = result.placeSuggestion else { return nil }
          return LocationSuggestion(
            id: place.placeID,
            title: place.attributedPrimaryText.string,
            subtitle: place.attributedSecondaryText?.string ?? "",
            location: place.attributedFullText.string)
        }
        continuation.resume(returning: suggestions)
      }
    }
  }
}
