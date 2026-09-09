import Combine
import Foundation

struct LocationSuggestion: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let location: String
}

@MainActor
protocol LocationSuggesting {
  var isConfigured: Bool { get }
  func suggestions(for query: String) async throws -> [LocationSuggestion]
}

@MainActor
final class LocationAutocompleteModel: ObservableObject {
  @Published private(set) var suggestions: [LocationSuggestion] = []
  @Published private(set) var isLoading = false
  @Published private(set) var message: String?
  private let service: any LocationSuggesting
  private let debounce: Duration
  private var pending: Task<Void, Never>?
  private var generation = UUID()

  init(service: any LocationSuggesting, debounce: Duration = .milliseconds(350)) {
    self.service = service
    self.debounce = debounce
  }

  func search(_ text: String, isEditing: Bool) {
    clear()
    guard isEditing, let query = RallyLocation.value(text), query.count >= 3 else { return }
    guard query.count <= 200 else {
      message = "Keep your location under 200 characters."
      return
    }
    guard service.isConfigured else {
      message = "Place search is unavailable. You can still enter a location."
      return
    }
    let operation = generation
    let delay = debounce
    pending = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        guard let self, !Task.isCancelled, self.generation == operation else { return }
        self.isLoading = true
        let results = try await self.service.suggestions(for: query)
        guard !Task.isCancelled, self.generation == operation else { return }
        self.suggestions = Array(results.prefix(5))
        self.message =
          results.isEmpty ? "No places found. Try adding a city, or keep your typed location." : nil
        self.isLoading = false
      } catch {
        guard let self, !Task.isCancelled, self.generation == operation else { return }
        self.isLoading = false
        self.message = "Couldn’t load places. You can still enter a location."
      }
    }
  }

  func select(_ suggestion: LocationSuggestion) -> String? {
    guard suggestions.contains(suggestion) else { return nil }
    clear()
    return suggestion.location
  }

  func clear() {
    generation = UUID()
    pending?.cancel()
    pending = nil
    suggestions = []
    message = nil
    isLoading = false
  }
}
