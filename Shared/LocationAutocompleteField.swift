import SwiftUI

struct LocationAutocompleteField: View {
  let title: String
  @Binding var text: String
  var cornerRadius: CGFloat = 6
  @StateObject private var model = LocationAutocompleteModel(service: GooglePlacesAutocomplete())
  @FocusState private var isEditing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title.lowercased()).font(.subheadline.weight(.semibold))
      HStack(spacing: 0) {
        TextField(("search for a place or address").lowercased(), text: $text, axis: .vertical)
          .lineLimit(1...3)
          .font(.system(size: 14))
          .textFieldStyle(.plain)
          .accessibilityLabel(title)
          .focused($isEditing)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .submitLabel(.done)
          .padding(.vertical, 12)
          .onSubmit {
            isEditing = false
            model.clear()
          }
        if !text.isEmpty {
          Button {
            text = ""
            model.clear()
            isEditing = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear \(title.lowercased())")
        }
      }
      .padding(.leading, 12)
      .padding(.trailing, text.isEmpty ? 12 : 0)
      .foregroundStyle(RallyDesign.ink)
      .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(isEditing ? RallyDesign.red : RallyDesign.border, lineWidth: 1)
      }
      if model.isLoading {
        ProgressView("finding places…").font(.caption)
      }
      if let message = model.message {
        Text((message).lowercased()).font(.caption).foregroundStyle(.secondary)
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
                Text((suggestion.title).lowercased()).font(.body)
                if !suggestion.subtitle.isEmpty {
                  Text((suggestion.subtitle).lowercased()).font(.caption).foregroundStyle(
                    .secondary)
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
