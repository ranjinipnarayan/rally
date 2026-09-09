import Foundation

@MainActor
private final class ControlledPlaces: LocationSuggesting {
  var isConfigured = true
  var queries: [String] = []
  var replies: [String: CheckedContinuation<[LocationSuggestion], Error>] = [:]

  func suggestions(for query: String) async throws -> [LocationSuggestion] {
    queries.append(query)
    return try await withCheckedThrowingContinuation { replies[query] = $0 }
  }

  func finish(_ query: String, with results: [LocationSuggestion]) {
    replies.removeValue(forKey: query)!.resume(returning: results)
  }
}

@main
struct LocationAutocompleteChecks {
  @MainActor
  static func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    preconditionFailure("Timed out waiting for autocomplete state")
  }

  @MainActor
  static func main() async throws {
    let service = ControlledPlaces()
    let model = LocationAutocompleteModel(service: service, debounce: .milliseconds(20))
    let old = LocationSuggestion(
      id: "old", title: "Old Cafe", subtitle: "Boston", location: "Old Cafe, Boston")
    let new = LocationSuggestion(
      id: "new", title: "New Cafe", subtitle: "New York", location: "New Cafe, New York")

    model.search("ca", isEditing: true)
    model.search("cafe", isEditing: false)
    try await Task.sleep(for: .milliseconds(30))
    precondition(service.queries.isEmpty, "Short or unfocused input must not make requests")

    for placeholder in ["To be decided", "  TO BE DECIDED\n", "   "] {
      model.search(placeholder, isEditing: true)
      try await Task.sleep(for: .milliseconds(30))
      precondition(service.queries.isEmpty, "An undecided location must not be sent to Google")
      precondition(model.suggestions.isEmpty && model.message == nil && !model.isLoading)
    }
    precondition(RallyLocation.value("To Be Decided Cafe") == "To Be Decided Cafe")

    model.search("caf", isEditing: true)
    model.search("cafe", isEditing: true)
    model.search("  cafe nyc  ", isEditing: true)
    try await eventually { service.queries.count == 1 }
    precondition(service.queries == ["cafe nyc"], "Rapid typing must be debounced")
    model.search("cafe boston", isEditing: true)
    try await eventually { service.queries.count == 2 }
    service.finish("cafe boston", with: [new])
    try await eventually { model.suggestions == [new] }
    service.finish("cafe nyc", with: [old])
    try await Task.sleep(for: .milliseconds(5))
    precondition(model.suggestions == [new], "Late results replaced the current suggestions")
    precondition(model.select(old) == nil, "A stale row must not overwrite the location")
    precondition(model.select(new) == "New Cafe, New York")
    precondition(model.suggestions.isEmpty && !model.isLoading)

    model.search("museum", isEditing: true)
    try await eventually { service.replies["museum"] != nil }
    model.clear()
    service.finish("museum", with: [old])
    try await Task.sleep(for: .milliseconds(5))
    precondition(model.suggestions.isEmpty, "Dismissed searches must remain cleared")

    model.search("library", isEditing: true)
    try await eventually { service.replies["library"] != nil }
    service.replies.removeValue(forKey: "library")!.resume(
      throwing: URLError(.notConnectedToInternet))
    try await eventually { model.message != nil }
    precondition(!model.isLoading && model.suggestions.isEmpty)

    service.isConfigured = false
    let calls = service.queries.count
    model.search("park", isEditing: true)
    precondition(model.message != nil && service.queries.count == calls)
    model.search(String(repeating: "a", count: 201), isEditing: true)
    precondition(service.queries.count == calls)
    print(
      "PASS: undecided locations, autocomplete debounce, stale response isolation, selection, dismissal, offline fallback, missing configuration, query limits"
    )
  }
}
