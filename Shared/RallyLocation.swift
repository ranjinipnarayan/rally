import Foundation

enum RallyLocation {
  static func value(_ text: String?) -> String? {
    guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.caseInsensitiveCompare("To be decided") != .orderedSame
    else { return nil }
    return value
  }
}
