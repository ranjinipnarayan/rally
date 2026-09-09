import Foundation

enum RallyAuthConfiguration {
  static let projectURL = URL(string: "https://ynfuafalrvgcszyxpguy.supabase.co")!
  // Public browser key from the same deployed website, never a service-role key.
  static let publishableKey = "sb_publishable_4C9X83WeyexVizPm-P3GIw_m5cpnak6"
  static let callbackURL = URL(string: "com.example.RallyMessages://auth/callback")!
  static let storageKey = "rally-auth-v1"

  static func acceptsCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == callbackURL.scheme?.lowercased()
      && url.host == "auth" && url.path == "/callback"
      && url.user == nil && url.password == nil && url.port == nil
  }
}
