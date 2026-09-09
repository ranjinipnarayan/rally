import Auth
import Combine
import Foundation
import Security

private struct NativeAuthStorage: AuthLocalStorage {
  let configuration: SharedSessionConfiguration

  private func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: configuration.service,
      kSecAttrAccount as String: key,
      kSecAttrAccessGroup as String: configuration.keychainAccessGroup,
    ]
  }

  func store(key: String, value: Data) throws {
    let query = query(key)
    let attributes: [String: Any] = [
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var newItem = query
      for (key, value) in attributes { newItem[key] = value }
      guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
        throw NativeLoginError.storage
      }
    } else if status != errSecSuccess {
      throw NativeLoginError.storage
    }
  }

  func retrieve(key: String) throws -> Data? {
    var query = query(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw NativeLoginError.storage
    }
    return data
  }

  func remove(key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NativeLoginError.storage
    }
  }
}

enum NativeLoginError: LocalizedError {
  case storage, configuration, callback, identity
  var errorDescription: String? {
    switch self {
    case .storage:
      "Couldn’t access your secure Rally session. Please unlock your device and try again."
    case .configuration: "Shared sign-in isn’t configured for this build yet."
    case .callback: "This sign-in link is invalid or expired. Request a new link."
    case .identity: "Couldn’t verify your Rally account. Please sign in again."
    }
  }
}

@MainActor
final class RallyAccountModel: ObservableObject {
  @Published private(set) var account: RallyAccount?
  @Published private(set) var rallies: [OrganizerRally] = []
  @Published private(set) var busy = false
  @Published private(set) var loading = true
  @Published private(set) var errorMessage: String?
  @Published private(set) var notice: String?
  private let api = RallyAccountAPI()
  private let storage: NativeAuthStorage?
  private let auth: AuthClient?
  private var generation = UUID()

  init() {
    if let configuration = SharedSessionConfiguration.configured {
      let storage = NativeAuthStorage(configuration: configuration)
      self.storage = storage
      auth = AuthClient(
        url: RallyAuthConfiguration.projectURL.appendingPathComponent("auth/v1"),
        headers: ["apikey": RallyAuthConfiguration.publishableKey],
        flowType: .pkce,
        redirectToURL: RallyAuthConfiguration.callbackURL,
        storageKey: RallyAuthConfiguration.storageKey,
        localStorage: storage,
        autoRefreshToken: false,
        emitLocalSessionAsInitialSession: true
      )
    } else {
      storage = nil
      auth = nil
    }
  }

  func sendLink(email: String) async {
    guard !busy else { return }
    busy = true
    errorMessage = nil
    notice = nil
    defer { busy = false }
    do {
      guard let auth, let storage,
        FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: storage.configuration.appGroupID) != nil
      else { throw NativeLoginError.configuration }
      try await auth.signInWithOTP(
        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
        redirectTo: RallyAuthConfiguration.callbackURL, shouldCreateUser: true)
      notice = "Check your email and open the sign-in link on this device."
    } catch {
      errorMessage = message(
        for: error,
        fallback: "Couldn’t send the sign-in link. Check your email address or try again later.")
    }
  }

  func handleCallback(_ url: URL) async {
    guard RallyAuthConfiguration.acceptsCallback(url) else { return }
    guard let auth else {
      errorMessage = NativeLoginError.configuration.localizedDescription
      return
    }
    generation = UUID()
    let operation = generation
    busy = true
    errorMessage = nil
    defer {
      busy = false
      loading = false
    }
    do {
      let session = try await auth.session(from: url)
      try await accept(session, operation: operation)
      notice = nil
    } catch {
      guard generation == operation else { return }
      errorMessage = message(for: error, fallback: NativeLoginError.callback.localizedDescription)
    }
  }

  func refresh() async {
    guard !busy else { return }
    busy = true
    errorMessage = nil
    let operation = generation
    defer {
      busy = false
      loading = false
    }
    do {
      guard let auth else { throw NativeLoginError.configuration }
      guard auth.currentSession != nil else {
        account = nil
        rallies = []
        if let storage { try storage.remove(key: storage.configuration.account) }
        return
      }
      try await accept(auth.session, operation: operation)
    } catch {
      guard generation == operation else { return }
      await handleUnauthorized(error)
      if auth?.currentSession == nil {
        account = nil
        rallies = []
        if let storage { try? storage.remove(key: storage.configuration.account) }
      }
      errorMessage = message(
        for: error, fallback: "Couldn’t refresh your Rallies. Please try again.")
    }
  }

  private func accept(_ session: Session, operation: UUID) async throws {
    let verified = try await api.me(token: session.accessToken)
    guard generation == operation else { return }
    guard verified.id.lowercased() == session.user.id.uuidString.lowercased() else {
      throw NativeLoginError.identity
    }
    try writeSharedSession(session)
    if account?.id != verified.id { rallies = [] }
    account = verified
    let list = try await api.list(token: session.accessToken)
    guard generation == operation else { return }
    rallies = list
  }

  private func writeSharedSession(_ session: Session) throws {
    guard let storage else { throw NativeLoginError.configuration }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let snapshot = OrganizerSession(
      userID: session.user.id.uuidString.lowercased(),
      accessToken: session.accessToken,
      expiresAt: Date(timeIntervalSince1970: session.expiresAt))
    try storage.store(key: storage.configuration.account, value: encoder.encode(snapshot))
  }

  func signOut() async {
    guard !busy else { return }
    generation = UUID()
    busy = true
    notice = nil
    errorMessage = nil
    defer { busy = false }
    do {
      if let storage { try storage.remove(key: storage.configuration.account) }
      account = nil
      rallies = []
      try await auth?.signOut(scope: .local)
    } catch {
      errorMessage = message(
        for: error,
        fallback: "Signed out on this device. The server couldn’t be reached to revoke the session."
      )
    }
  }

  private func token() async throws -> String {
    guard let auth, account != nil else { throw AccountAPIError.unauthorized }
    let operation = generation
    let session: Session
    do { session = try await auth.session } catch {
      if generation == operation, auth.currentSession == nil {
        await handleUnauthorized(AccountAPIError.unauthorized)
      }
      throw error
    }
    guard generation == operation,
      session.user.id.uuidString.lowercased() == account?.id.lowercased()
    else { throw AccountAPIError.unauthorized }
    try writeSharedSession(session)
    return session.accessToken
  }

  func detail(id: String) async throws -> OrganizerDetail {
    let operation = generation
    let value = try await token()
    do { return try await api.detail(id: id, token: value) } catch {
      if generation == operation { await handleUnauthorized(error) }
      throw error
    }
  }

  func update(id: String, action: String, time: Date? = nil, location: String? = nil) async throws
    -> OrganizerDetail
  {
    let operation = generation
    let value = try await token()
    do {
      let detail = try await api.update(
        id: id, action: action, time: time, location: location, token: value)
      await refresh()
      return detail
    } catch {
      if generation == operation { await handleUnauthorized(error) }
      throw error
    }
  }

  private func handleUnauthorized(_ error: Error) async {
    guard case AccountAPIError.unauthorized = error else { return }
    generation = UUID()
    account = nil
    rallies = []
    if let storage { try? storage.remove(key: storage.configuration.account) }
    try? await auth?.signOut(scope: .local)
    errorMessage = AccountAPIError.unauthorized.localizedDescription
  }

  func message(for error: Error, fallback: String = "Something went wrong. Please try again.")
    -> String
  {
    if let error = error as? NativeLoginError { return error.localizedDescription }
    if let error = error as? AccountAPIError { return error.localizedDescription }
    return fallback
  }
}
