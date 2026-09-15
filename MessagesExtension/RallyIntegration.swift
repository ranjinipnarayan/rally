import Combine
import Foundation
import Security

enum ScheduleMode: String {
  case specific
  case poll
}

enum LocationMode: String {
  case specific
  case open
}

// Domain input only. The API adapter will map this to the agreed backend schema.
struct PlanPayload: Equatable {
  let activity: String
  let scheduleMode: ScheduleMode
  let specificDate: Date?
  let pollCandidates: [Date]
  let locationMode: LocationMode
  let location: String

  func validate(now: Date = Date()) throws {
    guard !activity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      activity.utf16.count <= 200, location.utf16.count <= 200,
      locationMode != .specific || !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw RallyIntegrationError.invalidPlan }
    switch scheduleMode {
    case .specific:
      guard let specificDate, specificDate > now, pollCandidates.isEmpty else {
        throw RallyIntegrationError.invalidPlan
      }
    case .poll:
      guard specificDate == nil, (1...3).contains(pollCandidates.count),
        Set(pollCandidates).count == pollCandidates.count, pollCandidates.allSatisfy({ $0 > now })
      else { throw RallyIntegrationError.invalidPlan }
    }
  }
}

struct OrganizerSession: Codable {
  let userID: String
  let accessToken: String
  let expiresAt: Date

  var isValid: Bool {
    !userID.isEmpty && !accessToken.isEmpty && expiresAt > Date()
  }
}

protocol OrganizerSessionProviding {
  func session() throws -> OrganizerSession?
}

struct SharedSessionConfiguration: Sendable {
  let appGroupID: String
  let keychainAccessGroup: String
  let service: String
  let account: String

  static var configured: SharedSessionConfiguration? {
    guard
      let accessGroup = Bundle.main.object(forInfoDictionaryKey: "RallyKeychainAccessGroup")
        as? String,
      !accessGroup.isEmpty, !accessGroup.contains("$(")
    else { return nil }
    return SharedSessionConfiguration(
      appGroupID: "group.com.example.RallyMessages",
      keychainAccessGroup: accessGroup,
      service: "com.example.RallyMessages.auth",
      account: "rally-organizer-session-v1"
    )
  }
}

struct SharedKeychainSessionProvider: OrganizerSessionProviding {
  // Read the containing app's access-token snapshot; only the app refreshes it.
  // Never store tokens in App Group UserDefaults or bundled configuration.
  let configuration: SharedSessionConfiguration?

  func session() throws -> OrganizerSession? {
    guard let configuration else { return nil }
    guard
      FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: configuration.appGroupID
      ) != nil
    else { throw RallyIntegrationError.sessionUnavailable }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccessGroup as String: configuration.keychainAccessGroup,
      kSecAttrService as String: configuration.service,
      kSecAttrAccount as String: configuration.account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw RallyIntegrationError.sessionUnavailable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let session = try? decoder.decode(OrganizerSession.self, from: data) else {
      throw RallyIntegrationError.sessionUnavailable
    }
    return session.isValid ? session : nil
  }
}

struct CreatedRally {
  let id: String
  let title: String
  let publicURL: URL

  func validate() throws {
    guard !id.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      publicURL.scheme?.lowercased() == "https",
      let host = publicURL.host?.lowercased(),
      ["rally-your-friends.com", "www.rally-your-friends.com"].contains(host),
      publicURL.user == nil, publicURL.password == nil,
      publicURL.port == nil || publicURL.port == 443,
      publicURL.query == nil, publicURL.fragment == nil,
      publicURL.path.range(of: "^/r/[a-z0-9]{16,64}$", options: .regularExpression) != nil
    else { throw RallyIntegrationError.invalidPublicURL }
  }
}

protocol RallyCreating {
  func create(plan: PlanPayload, session: OrganizerSession) async throws -> CreatedRally
}

struct RallyAPI: RallyCreating {
  private let transport: URLSession
  private let endpoint = URL(string: "https://rally-your-friends.com/api/v1/rallies")!

  init(transport: URLSession? = nil) {
    if let transport {
      self.transport = transport
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      configuration.urlCredentialStorage = nil
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 45
      self.transport = URLSession(configuration: configuration)
    }
  }

  private struct CreateBody: Encodable {
    let activity: String
    let timeMode: String
    let timeZone: String
    let startsAt: String?
    let locationMode: String
    let location: String?
    let candidates: [String]
    let status = "open"

    enum CodingKeys: String, CodingKey {
      case activity, timeMode, timeZone, startsAt, locationMode, location, candidates, status
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(activity, forKey: .activity)
      try container.encode(timeMode, forKey: .timeMode)
      try container.encode(timeZone, forKey: .timeZone)
      // These keys are required even when their values are null.
      try container.encode(startsAt, forKey: .startsAt)
      try container.encode(locationMode, forKey: .locationMode)
      try container.encode(location, forKey: .location)
      try container.encode(candidates, forKey: .candidates)
      try container.encode(status, forKey: .status)
    }
  }

  private struct CreateResponse: Decodable {
    let id: String
    let title: String
    let publicUrl: URL
    // Deliberately do not decode or retain creatorToken / inviteToken.
  }

  private struct ErrorResponse: Decodable {
    struct Detail: Decodable {
      let code: String
      let message: String
    }
    let error: Detail
  }

  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      // Never replay a creation POST or forward its bearer to a redirect.
      completionHandler(nil)
    }
  }

  func create(plan: PlanPayload, session: OrganizerSession) async throws -> CreatedRally {
    try plan.validate()
    let responseData = try await send(plan: plan, session: session)
    do {
      let saved = try JSONDecoder().decode(CreateResponse.self, from: responseData)
      let rally = CreatedRally(id: saved.id, title: saved.title, publicURL: saved.publicUrl)
      try rally.validate()
      return rally
    } catch {
      throw RallyIntegrationError.creationUncertain
    }
  }

  private func send(plan: PlanPayload, session: OrganizerSession) async throws -> Data {
    guard session.isValid else { throw RallyIntegrationError.signInRequired }
    let formatter = ISO8601DateFormatter()
    let body = CreateBody(
      activity: plan.activity.trimmingCharacters(in: .whitespacesAndNewlines),
      timeMode: plan.scheduleMode.rawValue,
      timeZone: TimeZone.current.identifier,
      startsAt: plan.specificDate.map { formatter.string(from: $0) },
      locationMode: plan.locationMode.rawValue,
      location: plan.locationMode == .open
        ? nil : plan.location.trimmingCharacters(in: .whitespacesAndNewlines),
      candidates: plan.pollCandidates.map { formatter.string(from: $0) }
    )
    let data = try JSONEncoder().encode(body)
    guard data.count <= 16_384 else { throw RallyIntegrationError.invalidPlan }
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "POST"
    request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data

    let responseData: Data
    let response: URLResponse
    do {
      (responseData, response) = try await transport.data(for: request, delegate: NoRedirects())
    } catch {
      // v1 has no idempotency support: a lost response may follow a saved POST.
      throw RallyIntegrationError.creationUncertain
    }
    guard let http = response as? HTTPURLResponse else {
      throw RallyIntegrationError.creationUncertain
    }
    if http.statusCode == 401 { throw RallyIntegrationError.signInRequired }
    if [400, 404, 405, 409, 413, 415, 429].contains(http.statusCode) {
      let failure = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
      throw RallyIntegrationError.requestRejected(
        failure?.error.message
          ?? "Rally couldn’t accept this plan. Check the details and try again."
      )
    }
    guard http.statusCode == 201 else {
      throw RallyIntegrationError.creationUncertain
    }
    return responseData
  }

}

enum RallyIntegrationError: LocalizedError {
  case sessionUnavailable, signInRequired, invalidPlan
  case creationUncertain
  case requestRejected(String)
  case invalidPublicURL, conversationUnavailable, organizerChanged

  var errorDescription: String? {
    switch self {
    case .creationUncertain:
      "Rally may have been saved, but its link didn’t arrive. Check My Rallies on the website before creating another."
    case .requestRejected(let message): message
    case .sessionUnavailable: "Couldn’t read your Rally session. Open Rally to sign in."
    case .signInRequired: "Open Rally to sign in."
    case .invalidPlan:
      "Check your plan, location, and future times. Poll options must be different."
    case .invalidPublicURL: "Rally didn’t return a valid public link. Please try again."
    case .conversationUnavailable: "Return to your conversation and try adding the link again."
    case .organizerChanged: "Your Rally account changed. Review your plan before creating it again."
    }
  }
}

@MainActor
final class RallySubmissionModel: ObservableObject {
  @Published private(set) var isSignedIn = false
  @Published private(set) var isSubmitting = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var createdRally: CreatedRally?
  @Published private(set) var requiresCreationReview = false

  private let sessions: OrganizerSessionProviding
  private let backend: RallyCreating
  private struct CreationAttempt {
    let plan: PlanPayload
    let organizerID: String
    var outcomeUncertain = false
    var result: CreatedRally?
  }

  // Keep the request identity separate from visible authentication state. A
  // refresh or temporary logout must not turn an insertion retry into a new Rally.
  private var attempt: CreationAttempt?

  init(
    sessions: OrganizerSessionProviding = SharedKeychainSessionProvider(configuration: .configured),
    backend: RallyCreating = RallyAPI()
  ) {
    self.sessions = sessions
    self.backend = backend
  }

  func refreshSession() {
    do {
      let session = try sessions.session()
      isSignedIn = session?.isValid == true
      createdRally =
        isSignedIn && session?.userID == attempt?.organizerID
        ? attempt?.result : nil
      requiresCreationReview = attempt?.outcomeUncertain == true
      errorMessage =
        requiresCreationReview ? RallyIntegrationError.creationUncertain.localizedDescription : nil
    } catch {
      isSignedIn = false
      createdRally = nil
      errorMessage = RallyIntegrationError.sessionUnavailable.localizedDescription
    }
  }

  func planDidChange(_ plan: PlanPayload) {
    guard !isSubmitting, !requiresCreationReview, attempt?.plan != plan else { return }
    attempt = nil
    createdRally = nil
    errorMessage = nil
  }

  func submit(
    _ plan: PlanPayload,
    insert: (CreatedRally) async throws -> Void
  ) async {
    guard !isSubmitting else { return }
    isSubmitting = true
    errorMessage = nil
    defer { isSubmitting = false }
    var requestSession: OrganizerSession?
    var creationStarted = false

    do {
      guard let session = try sessions.session(), session.isValid else {
        isSignedIn = false
        throw RallyIntegrationError.signInRequired
      }
      if requiresCreationReview {
        throw RallyIntegrationError.creationUncertain
      }
      requestSession = session
      isSignedIn = true
      if attempt?.plan != plan || attempt?.organizerID != session.userID {
        attempt = CreationAttempt(plan: plan, organizerID: session.userID)
        createdRally = nil
      }
      guard let currentAttempt = attempt else { return }
      if currentAttempt.result == nil {
        try plan.validate()
        creationStarted = true
        let result = try await backend.create(plan: plan, session: session)
        try result.validate()
        // Cache the saved result even if login changed during the request;
        // only the creating organizer can expose it or insert its link.
        attempt?.result = result
      }
      guard let current = try sessions.session(), current.isValid else {
        throw RallyIntegrationError.signInRequired
      }
      isSignedIn = true
      guard current.userID == session.userID else {
        createdRally = nil
        throw RallyIntegrationError.organizerChanged
      }
      createdRally = attempt?.result
      guard let createdRally else { return }
      try await insert(createdRally)
    } catch {
      // Keep the plan and saved result so insertion failures do not create
      // another Rally. Never expose server response bodies or credentials.
      var integrationError = error as? RallyIntegrationError
      if creationStarted && attempt?.result == nil {
        switch integrationError {
        case .signInRequired, .invalidPlan, .requestRejected:
          break
        default:
          attempt?.outcomeUncertain = true
          integrationError = .creationUncertain
        }
      }
      requiresCreationReview = attempt?.outcomeUncertain == true
      if let failure = integrationError {
        switch failure {
        case .signInRequired:
          let latest = try? sessions.session()
          if let previous = requestSession, let latest, latest.isValid,
            latest.userID != previous.userID || latest.accessToken != previous.accessToken
          {
            // A delayed rejection of an old session must not sign out
            // the organizer who has since signed in or refreshed it.
            isSignedIn = true
            createdRally = latest.userID == attempt?.organizerID ? attempt?.result : nil
            integrationError = latest.userID == previous.userID ? nil : .organizerChanged
          } else {
            isSignedIn = false
            createdRally = nil
          }
        case .sessionUnavailable:
          isSignedIn = false
          createdRally = nil
        default:
          break
        }
      }
      errorMessage =
        integrationError?.localizedDescription
        ?? "Couldn’t finish sharing your Rally. Your plan is still here. Please try again."
    }
  }
}
