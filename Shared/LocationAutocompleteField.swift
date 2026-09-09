import SwiftUI

struct LocationAutocompleteField: View {
  let title: String
  @Binding var text: String
  @StateObject private var model = LocationAutocompleteModel(service: GooglePlacesAutocomplete())
  @FocusState private var isEditing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(title, text: $text)
        .focused($isEditing)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .onSubmit {
          isEditing = false
          model.clear()
        }
      if model.isLoading {
        ProgressView("Finding places…").font(.caption)
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      if !model.suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(model.suggestions) { suggestion in
            Button {
              if let location = model.select(suggestion) {
                isEditing = false
                text = location
              }
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title).font(.body)
                if !suggestion.subtitle.isEmpty {
                  Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Use this location")
            Divider()
          }
          // Compact text attribution is supported for space-constrained interfaces.
          Text(verbatim: "Google Maps")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color(white: 31.0 / 255))
            .fixedSize()
            .padding(.top, 10)
        }
      }
    }
    .onChange(of: text) { _, value in model.search(value, isEditing: isEditing) }
    .onChange(of: isEditing) { _, focused in model.search(text, isEditing: focused) }
    .onDisappear { model.clear() }
  }
}
