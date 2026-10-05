import SwiftUI

struct TimeZonePicker: View {
  let selection: TimeZone
  let onSelect: (TimeZone) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var search = ""

  private static let timeZones = Set(TimeZone.knownTimeZoneIdentifiers + ["Etc/UTC"]).compactMap {
    TimeZone(identifier: $0)
  }.sorted { $0.identifier < $1.identifier }

  private var matches: [TimeZone] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.timeZones.filter { zone in
      query.isEmpty || zone.identifier.localizedStandardContains(query)
        || Self.name(for: zone).localizedStandardContains(query)
        || (zone.localizedName(for: .generic, locale: .current) ?? "")
          .localizedStandardContains(query)
    }
  }

  static func name(for zone: TimeZone) -> String {
    if zone.identifier == "Etc/UTC" { return "UTC" }
    return zone.identifier.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "/", with: " / ")
  }

  var body: some View {
    NavigationStack {
      List {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Section {
            timeZoneRow(.current, usePhoneTimeZone: true)
          }
        }
        Section(("timezones").lowercased()) {
          ForEach(matches, id: \.identifier) { zone in
            timeZoneRow(zone)
          }
        }
      }
      .overlay {
        if matches.isEmpty {
          ContentUnavailableView.search(text: search)
        }
      }
      .searchable(text: $search, prompt: "City or timezone")
      .navigationTitle(("timezone").lowercased())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(("done").lowercased()) { dismiss() }
        }
      }
    }
    .tint(RallyDesign.red)
    .preferredColorScheme(.light)
  }

  private func timeZoneRow(_ zone: TimeZone, usePhoneTimeZone: Bool = false) -> some View {
    Button {
      onSelect(zone)
      dismiss()
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text((usePhoneTimeZone ? "Phone timezone" : Self.name(for: zone)).lowercased())
          Text(
            (usePhoneTimeZone
              ? Self.name(for: zone)
              : (zone.localizedName(for: .generic, locale: .current) ?? zone.identifier))
              .lowercased()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if zone == selection {
          Image(systemName: "checkmark")
        }
      }
      .foregroundStyle(.black)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityAddTraits(zone == selection ? .isSelected : [])
  }
}
