import Foundation

enum RallyLocation {
  static func displayName(_ text: String?) -> String? {
    guard let location = value(text) else { return nil }
    return location.split(separator: ",", maxSplits: 1).first
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? location
  }

  static func value(_ text: String?) -> String? {
    guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.caseInsensitiveCompare("To be decided") != .orderedSame
    else { return nil }
    return value
  }
}
