import Foundation

enum RallyAuthConfiguration {
  static let projectURL = URL(string: "https://ynfuafalrvgcszyxpguy.supabase.co")!
  // Public browser key from the same deployed website, never a service-role key.
  static let publishableKey = "sb_publishable_4C9X83WeyexVizPm-P3GIw_m5cpnak6"
  static let callbackURL = URL(string: "com.example.RallyMessages://auth/callback")!
  static let storageKey = "rally-auth-v1"

  static func normalizedEmail(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func isValidEmail(_ email: String) -> Bool {
    normalizedEmail(email).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression)
      != nil
  }

  static func normalizedCode(_ code: String) -> String {
    code.filter { !$0.isWhitespace }
  }

  static func isValidCode(_ code: String) -> Bool {
    let code = normalizedCode(code)
    return (6...10).contains(code.count) && code.utf8.allSatisfy { (48...57).contains($0) }
  }

  static func acceptsCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == callbackURL.scheme?.lowercased()
      && url.host == "auth" && url.path == "/callback"
      && url.user == nil && url.password == nil && url.port == nil
  }
}
