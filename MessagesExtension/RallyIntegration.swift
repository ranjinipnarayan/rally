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

protocol RallyDraftSaving {
  func saveDraft(plan: PlanPayload, session: OrganizerSession, existingID: String?) async throws
    -> String
  func publishDraft(plan: PlanPayload, session: OrganizerSession, id: String) async throws
    -> CreatedRally
}

struct RallyAPI: RallyCreating, RallyDraftSaving {
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
    let startsAt: String?
    let locationMode: String
    let location: String?
    let candidates: [String]
    let status: String?
    let action: String?

    enum CodingKeys: String, CodingKey {
      case activity, timeMode, startsAt, locationMode, location, candidates, status, action
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(activity, forKey: .activity)
      try container.encode(timeMode, forKey: .timeMode)
      // These keys are required even when their values are null.
      try container.encode(startsAt, forKey: .startsAt)
      try container.encode(locationMode, forKey: .locationMode)
      try container.encode(location, forKey: .location)
      try container.encode(candidates, forKey: .candidates)
      try container.encodeIfPresent(status, forKey: .status)
      try container.encodeIfPresent(action, forKey: .action)
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
    let responseData = try await send(plan: plan, session: session, draft: false, existingID: nil)
    do {
      let saved = try JSONDecoder().decode(CreateResponse.self, from: responseData)
      let rally = CreatedRally(id: saved.id, title: saved.title, publicURL: saved.publicUrl)
      try rally.validate()
      return rally
    } catch {
      throw RallyIntegrationError.creationUncertain
    }
  }

  func saveDraft(plan: PlanPayload, session: OrganizerSession, existingID: String?) async throws
    -> String
  {
    struct DraftIdentity: Decodable { let id: String }
    struct DraftDetail: Decodable { let rally: DraftIdentity }
    let data = try await send(plan: plan, session: session, draft: true, existingID: existingID)
    do {
      let id =
        try existingID == nil
        ? JSONDecoder().decode(DraftIdentity.self, from: data).id
        : JSONDecoder().decode(DraftDetail.self, from: data).rally.id
      guard UUID(uuidString: id) != nil else { throw RallyIntegrationError.creationUncertain }
      return id
    } catch {
      throw RallyIntegrationError.creationUncertain
    }
  }

  func publishDraft(plan: PlanPayload, session: OrganizerSession, id: String) async throws
    -> CreatedRally
  {
    struct Detail: Decodable {
      struct Rally: Decodable {
        let id: String
        let activity: String
        let publicUrl: URL
        let status: String
        let publishedAt: String?
      }
      let rally: Rally
    }
    try plan.validate()
    let data = try await send(plan: plan, session: session, draft: false, existingID: id)
    do {
      let saved = try JSONDecoder().decode(Detail.self, from: data).rally
      guard saved.status == "open", saved.publishedAt != nil else {
        throw RallyIntegrationError.creationUncertain
      }
      let result = CreatedRally(id: saved.id, title: saved.activity, publicURL: saved.publicUrl)
      try result.validate()
      return result
    } catch { throw RallyIntegrationError.creationUncertain }
  }

  private func send(plan: PlanPayload, session: OrganizerSession, draft: Bool, existingID: String?)
    async throws -> Data
  {
    guard session.isValid else { throw RallyIntegrationError.signInRequired }
    guard plan.activity.utf16.count <= 200, plan.location.utf16.count <= 200,
      plan.pollCandidates.count <= 10
    else { throw RallyIntegrationError.invalidPlan }
    if let existingID, UUID(uuidString: existingID) == nil {
      throw RallyIntegrationError.invalidPlan
    }
    let formatter = ISO8601DateFormatter()
    let body = CreateBody(
      activity: plan.activity.trimmingCharacters(in: .whitespacesAndNewlines),
      timeMode: plan.scheduleMode.rawValue,
      startsAt: plan.specificDate.map { formatter.string(from: $0) },
      locationMode: plan.locationMode.rawValue,
      location: plan.locationMode == .open
        ? nil : plan.location.trimmingCharacters(in: .whitespacesAndNewlines),
      candidates: plan.pollCandidates.map { formatter.string(from: $0) },
      status: existingID == nil ? (draft ? "draft" : "open") : nil,
      action: existingID == nil ? nil : (draft ? "save" : "publish")
    )
    let data = try JSONEncoder().encode(body)
    guard data.count <= 16_384 else { throw RallyIntegrationError.invalidPlan }
    let url = existingID.map { endpoint.appendingPathComponent($0) } ?? endpoint
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = existingID == nil ? "POST" : "PATCH"
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
    guard http.statusCode == (existingID == nil ? 201 : 200) else {
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
  @Published private(set) var savedDraftID: String?
  private var draftReceipt: (owner: String, id: String)?
  private var draftOutcomeUncertain = false

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
      savedDraftID = isSignedIn && session?.userID == draftReceipt?.owner ? draftReceipt?.id : nil
      requiresCreationReview = draftOutcomeUncertain || attempt?.outcomeUncertain == true
      errorMessage =
        requiresCreationReview ? RallyIntegrationError.creationUncertain.localizedDescription : nil
    } catch {
      isSignedIn = false
      createdRally = nil
      errorMessage = RallyIntegrationError.sessionUnavailable.localizedDescription
    }
  }

  func draftDidChange(_ plan: PlanPayload) {
    guard !isSubmitting, !requiresCreationReview, attempt?.plan != plan else { return }
    attempt = nil
    createdRally = nil
    errorMessage = nil
  }

  func saveDraft(_ plan: PlanPayload) async {
    guard !isSubmitting else { return }
    isSubmitting = true
    errorMessage = nil
    defer { isSubmitting = false }
    var savingStarted = false
    var savingFinished = false
    var savingOwner: String?
    do {
      guard let session = try sessions.session(), session.isValid else {
        isSignedIn = false
        throw RallyIntegrationError.signInRequired
      }
      isSignedIn = true
      guard !requiresCreationReview else { throw RallyIntegrationError.creationUncertain }
      guard let drafts = backend as? RallyDraftSaving else {
        throw RallyIntegrationError.requestRejected(
          "Draft saving is unavailable. Please try again later.")
      }
      let existingID = session.userID == draftReceipt?.owner ? draftReceipt?.id : nil
      savingOwner = session.userID
      savingStarted = true
      let id = try await drafts.saveDraft(plan: plan, session: session, existingID: existingID)
      savingFinished = true
      draftReceipt = (session.userID, id)
      guard let current = try sessions.session(), current.isValid else {
        isSignedIn = false
        throw RallyIntegrationError.signInRequired
      }
      guard current.userID == session.userID else { throw RallyIntegrationError.organizerChanged }
      savedDraftID = id
    } catch {
      let failure = error as? RallyIntegrationError
      if savingStarted && !savingFinished {
        switch failure {
        case .requestRejected, .invalidPlan, .signInRequired: break
        default: draftOutcomeUncertain = true
        }
      }
      if case .signInRequired = failure {
        let latest = try? sessions.session()
        isSignedIn = latest?.isValid == true && latest?.userID != savingOwner
      }
      if case .sessionUnavailable = failure { isSignedIn = false }
      requiresCreationReview = draftOutcomeUncertain || attempt?.outcomeUncertain == true
      errorMessage =
        failure?.localizedDescription
        ?? RallyIntegrationError.creationUncertain.localizedDescription
    }
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
        let result: CreatedRally
        if let receipt = draftReceipt, receipt.owner == session.userID,
          let drafts = backend as? RallyDraftSaving
        {
          result = try await drafts.publishDraft(plan: plan, session: session, id: receipt.id)
          draftReceipt = nil
          savedDraftID = nil
        } else {
          result = try await backend.create(plan: plan, session: session)
        }
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
      // Keep the draft and saved result so insertion failures do not create
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
      requiresCreationReview = draftOutcomeUncertain || attempt?.outcomeUncertain == true
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
