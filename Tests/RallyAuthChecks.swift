import Auth
import Foundation

private final class MemoryAuthStorage: RallyAuthStorage, @unchecked Sendable {
  let configuration = SharedSessionConfiguration(
    appGroupID: "test-group", keychainAccessGroup: "test-keychain", service: "test-auth",
    account: "test-shared-session")
  let isAvailable: Bool
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  init(isAvailable: Bool = true) { self.isAvailable = isAvailable }

  func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
  func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
  func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }

  var sharedSession: OrganizerSession? {
    get throws {
      guard let data = try retrieve(key: configuration.account) else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(OrganizerSession.self, from: data)
    }
  }

  func checkNoSharedSession() throws {
    let session = try sharedSession
    precondition(session == nil)
  }
}

private let userID = "11111111-1111-4111-8111-111111111111"
private let authSessionJSON = """
  {"access_token":"test-access-token","refresh_token":"test-refresh-token",
   "token_type":"bearer","expires_in":3600,"expires_at":4099766400,
   "user":{"id":"\(userID)","aud":"authenticated","email":"rally@example.com",
   "app_metadata":{},"user_metadata":{},"created_at":"2026-01-01T00:00:00Z",
   "updated_at":"2026-01-01T00:00:00Z"}}
  """

private actor AuthRequests {
  var requests: [URLRequest] = []
  var failure: (Int, String)?

  func fail(status: Int, code: String) { failure = (status, code) }

  func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let status: Int
    let json: String
    if let failure {
      status = failure.0
      json = "{\"code\":\"\(failure.1)\",\"message\":\"Private server details\"}"
    } else {
      status = 200
      json = request.url?.lastPathComponent == "otp" ? "{}" : authSessionJSON
    }
    return (
      Data(json.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]
      )!
    )
  }
}

private final class AccountHTTP: URLProtocol {
  static var verifiedID = userID
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
    let json: String
    switch request.url?.path {
    case "/api/v1/me":
      json = "{\"user\":{\"id\":\"\(Self.verifiedID)\",\"email\":\"rally@example.com\"}}"
    case "/api/v1/rallies":
      json = #"{"rallies":[]}"#
    default:
      preconditionFailure("Unexpected account request")
    }
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor
private struct SignInHarness {
  let storage: MemoryAuthStorage
  let requests = AuthRequests()
  let auth: AuthClient
  let model: RallyAccountModel

  init(storageAvailable: Bool = true) {
    storage = MemoryAuthStorage(isAvailable: storageAvailable)
    auth = AuthClient(
      url: URL(string: "https://auth.example.com/auth/v1")!, flowType: .pkce,
      redirectToURL: RallyAuthConfiguration.callbackURL, localStorage: storage,
      fetch: { [requests] in try await requests.fetch($0) },
      autoRefreshToken: false, emitLocalSessionAsInitialSession: true)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountHTTP.self]
    model = RallyAccountModel(
      auth: auth, storage: storage,
      api: RallyAccountAPI(transport: URLSession(configuration: configuration)))
  }

  func checkSignedIn() throws {
    precondition(model.account?.id == userID)
    precondition(auth.currentSession?.user.id.uuidString.lowercased() == userID)
    let shared = try storage.sharedSession
    precondition(shared?.userID == userID && shared?.accessToken == "test-access-token")
    precondition(!model.busy && !model.isEnteringCode)
    precondition(model.signInEmail == nil && model.notice == nil && model.errorMessage == nil)
  }
}

@main
struct RallyAuthChecks {
  @MainActor
  static func main() async throws {
    let sent = SignInHarness()
    await sent.model.refresh()
    await sent.model.sendSignInEmail(email: " Rally@Example.com \n")
    precondition(sent.model.signInEmail == "rally@example.com" && sent.model.isEnteringCode)
    precondition(sent.model.account == nil && !sent.model.busy)
    let sendRequest = await sent.requests.requests[0]
    let sendBody = try JSONSerialization.jsonObject(with: sendRequest.httpBody!) as! [String: Any]
    precondition(sendRequest.url?.lastPathComponent == "otp" && sendRequest.httpMethod == "POST")
    precondition(sendBody["email"] as? String == "rally@example.com")
    precondition(sendBody["code_challenge"] as? String != nil)
    precondition(
      URLComponents(url: sendRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "redirect_to" })?.value
        == RallyAuthConfiguration.callbackURL.absoluteString)
    // Verification must use the address the email was sent to, even if an outdated view supplies another.
    await sent.model.verifyCode(email: "wrong@example.com", code: "012 345\n")
    try sent.checkSignedIn()
    let verifyRequest = await sent.requests.requests[1]
    let verifyBody =
      try JSONSerialization.jsonObject(with: verifyRequest.httpBody!) as! [String: Any]
    precondition(verifyRequest.url?.lastPathComponent == "verify")
    precondition(verifyBody["email"] as? String == "rally@example.com")
    precondition(verifyBody["token"] as? String == "012345")
    precondition(verifyBody["type"] as? String == "email")
    print(
      "PASS: email sends link + code; code verification preserves leading zeroes and shares verified session"
    )

    let existing = SignInHarness()
    await existing.model.refresh()
    existing.model.showCodeEntry()
    precondition(existing.model.isEnteringCode && existing.model.signInEmail == nil)
    await existing.model.verifyCode(email: " RALLY@example.com ", code: "0123456789")
    try existing.checkSignedIn()
    let existingRequests = await existing.requests.requests
    precondition(
      existingRequests.count == 1 && existingRequests[0].url?.lastPathComponent == "verify")
    print(
      "PASS: existing email code signs in without sending a new email or needing a PKCE verifier")

    let link = SignInHarness()
    await link.model.sendSignInEmail(email: "rally@example.com")
    await link.model.handleCallback(
      URL(string: "com.example.RallyMessages://auth/callback?code=test-link-code")!)
    try link.checkSignedIn()
    let linkRequest = await link.requests.requests.last!
    precondition(linkRequest.url?.lastPathComponent == "token")
    print("PASS: email link still completes PKCE sign-in and shares the session")

    let invalid = SignInHarness()
    invalid.model.showCodeEntry()
    for code in ["", "12345", "12345678901", "12345a", "１２３４５６"] {
      await invalid.model.verifyCode(email: "rally@example.com", code: code)
      precondition(invalid.model.errorMessage == NativeLoginError.code.localizedDescription)
    }
    await invalid.model.verifyCode(email: "invalid", code: "123456")
    precondition(invalid.model.errorMessage == NativeLoginError.email.localizedDescription)
    let invalidRequests = await invalid.requests.requests
    precondition(invalidRequests.isEmpty)
    try invalid.storage.checkNoSharedSession()
    print("PASS: malformed codes and email addresses never send verification requests")

    for (status, code, expected) in [
      (403, "otp_expired", "invalid, expired, or already used"),
      (403, "otp_disabled", "invalid, expired, or already used"),
      (429, "over_request_rate_limit", "Too many sign-in attempts"),
      (400, "unexpected_error", "Could not verify the code"),
    ] {
      let failed = SignInHarness()
      failed.model.showCodeEntry()
      await failed.requests.fail(status: status, code: code)
      await failed.model.verifyCode(email: "rally@example.com", code: "123456")
      precondition(failed.model.errorMessage?.contains(expected) == true)
      precondition(failed.model.account == nil && failed.model.isEnteringCode && !failed.model.busy)
      try failed.storage.checkNoSharedSession()
      failed.model.resetSignIn()
      precondition(!failed.model.isEnteringCode && failed.model.errorMessage == nil)
    }
    print("PASS: expired/used codes, rate limits, and verification failures preserve retry flow")

    let unavailable = SignInHarness()
    await unavailable.requests.fail(status: 429, code: "over_email_send_rate_limit")
    await unavailable.model.sendSignInEmail(email: "rally@example.com")
    precondition(!unavailable.model.isEnteringCode && unavailable.model.signInEmail == nil)
    precondition(unavailable.model.errorMessage?.contains("temporarily unavailable") == true)

    let change = SignInHarness()
    await change.model.sendSignInEmail(email: "rally@example.com")
    change.model.resetSignIn()
    precondition(change.model.signInEmail == nil && change.model.notice == nil)
    await change.model.sendSignInEmail(email: "new@example.com")
    precondition(change.model.signInEmail == "new@example.com")
    print(
      "PASS: failed sends stay on email entry; change email/request a new code resets pending state"
    )

    let mismatch = SignInHarness()
    AccountHTTP.verifiedID = "22222222-2222-4222-8222-222222222222"
    await mismatch.model.verifyCode(email: "rally@example.com", code: "123456")
    precondition(mismatch.model.account == nil)
    precondition(mismatch.model.errorMessage == NativeLoginError.identity.localizedDescription)
    try mismatch.storage.checkNoSharedSession()
    AccountHTTP.verifiedID = userID

    let unconfigured = SignInHarness(storageAvailable: false)
    await unconfigured.model.verifyCode(email: "rally@example.com", code: "123456")
    precondition(
      unconfigured.model.errorMessage == NativeLoginError.configuration.localizedDescription)
    let unconfiguredRequests = await unconfigured.requests.requests
    precondition(unconfiguredRequests.isEmpty)
    print(
      "PASS: mismatched identity and unavailable shared storage cannot authenticate the extension")
  }
}
