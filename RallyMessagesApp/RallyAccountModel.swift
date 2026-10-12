import Auth
import Combine
import Foundation
import Security

protocol RallyAuthStorage: AuthLocalStorage {
  var configuration: SharedSessionConfiguration { get }
  var isAvailable: Bool { get }
}

private struct NativeAuthStorage: RallyAuthStorage {
  let configuration: SharedSessionConfiguration

  var isAvailable: Bool {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: configuration.appGroupID) != nil
  }

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
  case storage, configuration, callback, identity, email, code
  var errorDescription: String? {
    switch self {
    case .storage:
      "Couldn’t access your secure Rally session. Please unlock your device and try again."
    case .configuration: "Shared sign-in isn’t configured for this build yet."
    case .callback: "This sign-in link is invalid or expired. Request a new link."
    case .identity: "Couldn’t verify your Rally account. Please sign in again."
    case .email: "Enter a valid email address."
    case .code: "Enter the 6–10 digit code from your sign-in email."
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
  @Published private(set) var isEnteringCode = false
  @Published private(set) var signInEmail: String?
  private let deviceStore: DeviceRallyStoring
  private let api: RallyAccountAPI
  private let storage: (any RallyAuthStorage)?
  private let auth: AuthClient?
  private var generation = UUID()

  init() {
    api = RallyAccountAPI()
    deviceStore = SharedDeviceRallyStore(configuration: .configured)
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

  init(
    auth: AuthClient, storage: any RallyAuthStorage, api: RallyAccountAPI,
    deviceStore: DeviceRallyStoring = SharedDeviceRallyStore(configuration: .configured)
  ) {
    self.auth = auth
    self.storage = storage
    self.api = api
    self.deviceStore = deviceStore
  }

  func showCodeEntry() {
    guard !busy else { return }
    isEnteringCode = true
    errorMessage = nil
    notice = nil
  }

  func resetSignIn() {
    guard !busy else { return }
    clearSignIn()
    errorMessage = nil
  }

  private func clearSignIn() {
    isEnteringCode = false
    signInEmail = nil
    notice = nil
  }

  func sendSignInEmail(email: String) async {
    guard !busy else { return }
    let operation = generation
    busy = true
    errorMessage = nil
    notice = nil
    defer { if generation == operation { busy = false } }
    do {
      guard let auth, storage?.isAvailable == true else { throw NativeLoginError.configuration }
      let email = RallyAuthConfiguration.normalizedEmail(email)
      guard RallyAuthConfiguration.isValidEmail(email) else { throw NativeLoginError.email }
      try await auth.signInWithOTP(
        email: email,
        redirectTo: RallyAuthConfiguration.callbackURL, shouldCreateUser: true)
      guard generation == operation else { return }
      signInEmail = email
      isEnteringCode = true
      notice = "Check \(email)."
    } catch {
      guard generation == operation else { return }
      errorMessage = signInMessage(for: error, verifyingCode: false)
    }
  }

  func verifyCode(email: String, code: String) async {
    guard !busy else { return }
    let operation = generation
    busy = true
    errorMessage = nil
    defer { if generation == operation { busy = false } }
    do {
      guard let auth, storage?.isAvailable == true else { throw NativeLoginError.configuration }
      let email = signInEmail ?? RallyAuthConfiguration.normalizedEmail(email)
      let code = RallyAuthConfiguration.normalizedCode(code)
      guard RallyAuthConfiguration.isValidEmail(email) else { throw NativeLoginError.email }
      guard RallyAuthConfiguration.isValidCode(code) else { throw NativeLoginError.code }
      let response = try await auth.verifyOTP(email: email, token: code, type: .email)
      guard generation == operation else { return }
      guard let session = response.session else { throw NativeLoginError.identity }
      try await accept(session, operation: operation)
      guard generation == operation else { return }
      clearSignIn()
    } catch {
      guard generation == operation else { return }
      errorMessage = signInMessage(for: error, verifyingCode: true)
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
      if generation == operation {
        busy = false
        loading = false
      }
    }
    do {
      let session = try await auth.session(from: url)
      try await accept(session, operation: operation)
      guard generation == operation else { return }
      clearSignIn()
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
      guard let auth, auth.currentSession != nil else {
        account = nil
        rallies = []
        if let storage { try storage.remove(key: storage.configuration.account) }
        try await refreshDeviceRallies(operation: operation)
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
      try? await refreshDeviceRallies(operation: generation)
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
    for var record in try deviceStore.records() {
      if let summary = list.first(where: { $0.id == record.result.id }) {
        record.ownerID = verified.id
        record.summary = try JSONEncoder().encode(summary)
        try deviceStore.save(record)
      } else if record.ownerID?.lowercased() == verified.id.lowercased() {
        try deviceStore.remove(id: record.result.id)
      }
    }
    rallies = list
    try await refreshDeviceRallies(operation: operation)
  }

  private func deviceRecords() throws -> [DeviceRally] {
    try deviceStore.records().filter {
      $0.ownerID == nil || $0.ownerID?.lowercased() == account?.id.lowercased()
    }
  }

  func isGuestRally(id: String) -> Bool {
    (try? deviceRecords().contains { $0.result.id == id && $0.ownerID == nil }) == true
  }

  private func guestCredential(id: String) throws -> String? {
    try deviceRecords().first { $0.result.id == id && $0.ownerID == nil }?.result.creatorToken
  }

  private func cachedSummary(_ record: DeviceRally) -> OrganizerRally {
    if let data = record.summary,
      let cached = try? JSONDecoder().decode(OrganizerRally.self, from: data)
    {
      return cached
    }
    return OrganizerRally(
      id: record.result.id, activity: record.result.title,
      publicUrl: record.result.publicURL, time: record.plan.specificDate,
      location: record.plan.locationMode == .specific ? record.plan.location : nil,
      status: "open", nextAction: "waiting_for_responses", section: "active",
      archivedAt: nil, responseCount: 0)
  }

  private func refreshDeviceRallies(operation: UUID) async throws {
    let records = try deviceRecords()
    for record in records where !rallies.contains(where: { $0.id == record.result.id }) {
      rallies.append(cachedSummary(record))
    }
    for var record in records where record.ownerID == nil {
      do {
        let detail = try await api.detail(
          id: record.result.id, creatorToken: record.result.creatorToken)
        guard generation == operation else { return }
        let plan = detail.rally
        let summary = OrganizerRally(
          id: plan.id, activity: plan.activity, publicUrl: plan.publicUrl,
          time: plan.finalTime ?? plan.startsAt, location: plan.resolvedLocation,
          status: plan.status,
          nextAction: plan.nextAction,
          section: ["cancelled", "completed"].contains(plan.status)
            ? "past"
            : (plan.status == "draft"
              || (plan.status == "open" && plan.nextAction != "waiting_for_responses"
                && plan.nextAction != "none")
              ? "needs_you" : "active"),
          archivedAt: plan.archivedAt, responseCount: detail.responses.count)
        record.summary = try JSONEncoder().encode(summary)
        try deviceStore.save(record)
        rallies.removeAll { $0.id == summary.id }
        rallies.append(summary)
      } catch AccountAPIError.notFound {
        guard generation == operation else { return }
        try deviceStore.remove(id: record.result.id)
        rallies.removeAll { $0.id == record.result.id }
      } catch {
        guard generation == operation else { return }
        errorMessage = "Some rallies couldn’t refresh. Showing saved details; pull to refresh."
      }
    }
  }

  func claim(id: String) async throws {
    guard var record = try deviceRecords().first(where: { $0.result.id == id && $0.ownerID == nil })
    else {
      throw AccountAPIError.notFound
    }
    let operation = generation
    let value = try await token()
    let ownerID = account?.id
    try await api.claim(id: id, token: value, creatorToken: record.result.creatorToken)
    guard generation == operation else { throw AccountAPIError.unauthorized }
    record.ownerID = ownerID
    try deviceStore.save(record)
    await refresh()
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
    clearSignIn()
    errorMessage = nil
    defer { busy = false }
    do {
      if let storage { try storage.remove(key: storage.configuration.account) }
      account = nil
      rallies = []
      try await auth?.signOut(scope: .local)
      try await refreshDeviceRallies(operation: generation)
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
    let guest = try guestCredential(id: id)
    let value = guest == nil ? try await token() : nil
    do { return try await api.detail(id: id, token: value, creatorToken: guest) } catch {
      if generation == operation {
        if case AccountAPIError.notFound = error {
          try deviceStore.remove(id: id)
          rallies.removeAll { $0.id == id }
        }
        if guest == nil { await handleUnauthorized(error) }
      }
      throw error
    }
  }

  func update(id: String, action: String, time: Date? = nil, location: String? = nil) async throws
    -> OrganizerDetail
  {
    let operation = generation
    let guest = try guestCredential(id: id)
    let value = guest == nil ? try await token() : nil
    do {
      let detail = try await api.update(
        id: id, action: action, time: time, location: location, token: value, creatorToken: guest)
      await refresh()
      return detail
    } catch {
      if generation == operation, guest == nil { await handleUnauthorized(error) }
      throw error
    }
  }

  func delete(id: String) async throws {
    guard !busy else {
      throw AccountAPIError.server("Rally is refreshing. Please try again in a moment.")
    }
    busy = true
    defer { busy = false }
    let operation = generation
    let guest = try guestCredential(id: id)
    let value = guest == nil ? try await token() : nil
    do {
      try await api.delete(id: id, token: value, creatorToken: guest)
    } catch AccountAPIError.notFound {
      // An already-removed Rally should also leave the local list.
    } catch {
      if generation == operation, guest == nil { await handleUnauthorized(error) }
      throw error
    }
    guard generation == operation else { throw AccountAPIError.unauthorized }
    try deviceStore.remove(id: id)
    rallies.removeAll { $0.id == id }
    busy = false
    await refresh()
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

  private func signInMessage(for error: Error, verifyingCode: Bool) -> String {
    if case AuthError.api(_, let code, _, let response) = error {
      if response.statusCode == 429 || code == .overRequestRateLimit
        || code == .overEmailSendRateLimit
      {
        return verifyingCode
          ? "Too many sign-in attempts. Please try again later."
          : "Sign-in emails are temporarily unavailable. Please try again later."
      }
      if verifyingCode && (code == .otpExpired || code == .otpDisabled) {
        return "That code is invalid, expired, or already used. Request a new code and try again."
      }
      if !verifyingCode && response.statusCode >= 500 {
        return "Sign-in emails are temporarily unavailable. Please try again later."
      }
    }
    return message(
      for: error,
      fallback: verifyingCode
        ? "Could not verify the code. Check your email and code, then try again."
        : "Could not send the email. Check your email address or try again later.")
  }

  func message(for error: Error, fallback: String = "Something went wrong. Please try again.")
    -> String
  {
    if let error = error as? NativeLoginError { return error.localizedDescription }
    if let error = error as? AccountAPIError { return error.localizedDescription }
    return fallback
  }
}
