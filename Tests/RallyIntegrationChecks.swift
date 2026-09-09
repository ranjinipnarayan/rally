import Foundation

private final class TestSessions: OrganizerSessionProviding {
  var value: OrganizerSession? = OrganizerSession(
    userID: "organizer", accessToken: "test-only", expiresAt: Date().addingTimeInterval(3600)
  )
  var error: RallyIntegrationError?

  func session() throws -> OrganizerSession? {
    if let error { throw error }
    return value
  }
}

private final class TestBackend: RallyCreating, RallyDraftSaving {
  var draftCalls: [String?] = []
  var publishedDrafts: [String] = []
  func saveDraft(plan: PlanPayload, session: OrganizerSession, existingID: String?) async throws
    -> String
  {
    draftCalls.append(existingID)
    return existingID ?? "11111111-1111-4111-8111-111111111111"
  }
  func publishDraft(plan: PlanPayload, session: OrganizerSession, id: String) async throws
    -> CreatedRally
  {
    publishedDrafts.append(id)
    return result
  }
  var calls: [PlanPayload] = []
  var shouldFail = false
  var error: RallyIntegrationError?
  var beforeReturn: (() -> Void)?
  var result = CreatedRally(
    id: "saved", title: "Dinner",
    publicURL: URL(
      string: "https://www.rally-your-friends.com/r/abcdefghijkmnopqrstuvwxyz23456789")!
  )
  func create(plan: PlanPayload, session: OrganizerSession) async throws -> CreatedRally {
    calls.append(plan)
    beforeReturn?()
    if let error { throw error }
    if shouldFail { throw RallyIntegrationError.requestRejected("Check the plan.") }
    return result
  }
}

@MainActor
private final class SuspendedBackend: RallyCreating {
  private(set) var calls: [PlanPayload] = []
  private var response: CheckedContinuation<CreatedRally, Error>?
  private var started: CheckedContinuation<Void, Never>?
  private let result = CreatedRally(
    id: "saved", title: "Dinner",
    publicURL: URL(
      string: "https://www.rally-your-friends.com/r/abcdefghijkmnopqrstuvwxyz23456789")!
  )

  func create(plan: PlanPayload, session: OrganizerSession) async throws -> CreatedRally {
    calls.append(plan)
    guard calls.count == 1 else { return result }
    return try await withCheckedThrowingContinuation { continuation in
      response = continuation
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    guard response == nil else { return }
    await withCheckedContinuation { started = $0 }
  }

  func complete(error: RallyIntegrationError? = nil) {
    precondition(response != nil)
    if let error {
      response?.resume(throwing: error)
    } else {
      response?.resume(returning: result)
    }
    response = nil
  }
}

@main
struct RallyIntegrationChecks {
  @MainActor
  static func main() async throws {
    let future = Date().addingTimeInterval(86400)
    let plan = PlanPayload(
      activity: "Dinner", scheduleMode: .specific, specificDate: future,
      pollCandidates: [], locationMode: .open, location: "")
    let sessions = TestSessions()
    let backend = TestBackend()
    let model = RallySubmissionModel(sessions: sessions, backend: backend)
    model.refreshSession()
    precondition(model.isSignedIn)

    let draftSessions = TestSessions()
    draftSessions.value = nil
    let draftBackend = TestBackend()
    let draftModel = RallySubmissionModel(sessions: draftSessions, backend: draftBackend)
    let incomplete = PlanPayload(
      activity: "", scheduleMode: .poll, specificDate: nil,
      pollCandidates: [], locationMode: .specific, location: "")
    await draftModel.saveDraft(incomplete)
    precondition(!draftModel.isSignedIn && draftBackend.draftCalls.isEmpty)
    precondition(
      draftModel.errorMessage == RallyIntegrationError.signInRequired.localizedDescription)
    draftSessions.value = sessions.value
    await draftModel.saveDraft(incomplete)
    precondition(draftModel.savedDraftID != nil && draftModel.createdRally == nil)
    await draftModel.saveDraft(plan)
    precondition(
      draftBackend.draftCalls.count == 2 && draftBackend.draftCalls[1] == draftModel.savedDraftID)
    await draftModel.submit(plan) { _ in }
    precondition(draftBackend.calls.isEmpty && draftBackend.publishedDrafts.count == 1)
    precondition(draftModel.savedDraftID == nil && draftModel.createdRally != nil)

    var insertions = 0
    await model.submit(plan) { _ in
      throw RallyIntegrationError.conversationUnavailable
    }
    precondition(backend.calls.count == 1 && model.createdRally != nil && model.errorMessage != nil)
    await model.submit(plan) { result in
      precondition(result.id == "saved")
      insertions += 1
    }
    precondition(backend.calls.count == 1 && insertions == 1 && model.errorMessage == nil)
    precondition(!model.isSubmitting)

    let changed = PlanPayload(
      activity: "Coffee", scheduleMode: .specific, specificDate: future,
      pollCandidates: [], locationMode: .specific, location: "Cafe")
    model.draftDidChange(changed)
    precondition(model.createdRally == nil)
    backend.shouldFail = true
    await model.submit(changed) { _ in preconditionFailure("No insert after API failure") }
    await model.submit(changed) { _ in preconditionFailure("No insert after API failure") }
    precondition(backend.calls.count == 3)
    backend.shouldFail = false
    await model.submit(changed) { _ in insertions += 1 }
    precondition(backend.calls.count == 4 && insertions == 2)

    sessions.value = nil
    model.refreshSession()
    precondition(!model.isSignedIn && model.createdRally == nil)
    await model.submit(plan) { _ in preconditionFailure("Signed-out sharing") }
    precondition(backend.calls.count == 4)

    sessions.value = OrganizerSession(
      userID: "organizer", accessToken: "test-only", expiresAt: .distantPast)
    await model.submit(plan) { _ in preconditionFailure("Expired-session sharing") }
    precondition(backend.calls.count == 4)

    for count in 1...3 {
      try PlanPayload(
        activity: "Poll", scheduleMode: .poll, specificDate: nil,
        pollCandidates: (0..<count).map { future.addingTimeInterval(Double($0) * 3600) },
        locationMode: .open, location: ""
      ).validate()
    }
    for dates in [[], [future, future], [Date.distantPast]] as [[Date]] {
      do {
        try PlanPayload(
          activity: "Poll", scheduleMode: .poll, specificDate: nil,
          pollCandidates: dates, locationMode: .open, location: ""
        ).validate()
        preconditionFailure("Invalid poll accepted")
      } catch RallyIntegrationError.invalidPlan {}
    }

    try backend.result.validate()
    for url in [
      "http://www.rally-your-friends.com/r/abcdefghijkmnopqrstuvwxyz23456789",
      "https://evil.example/r/abcdefghijkmnopqrstuvwxyz23456789",
      "https://www.rally-your-friends.com/m/abcdefghijkmnopqrstuvwxyz23456789",
      "https://www.rally-your-friends.com/r/abcdefghijkmnopqrstuvwxyz23456789?access_token=secret",
      "https://www.rally-your-friends.com/",
    ] {
      do {
        try CreatedRally(id: "id", title: "Dinner", publicURL: URL(string: url)!).validate()
        preconditionFailure("Unsafe or non-public link accepted")
      } catch RallyIntegrationError.invalidPublicURL {}
    }

    let defaultModel = RallySubmissionModel()
    defaultModel.refreshSession()
    precondition(!defaultModel.isSignedIn)
    let uncertainBackend = TestBackend()
    uncertainBackend.error = .creationUncertain
    let uncertainModel = RallySubmissionModel(sessions: TestSessions(), backend: uncertainBackend)
    await uncertainModel.submit(plan) { _ in preconditionFailure("Unknown creation shared") }
    precondition(uncertainModel.requiresCreationReview)
    uncertainModel.refreshSession()
    uncertainModel.draftDidChange(changed)
    await uncertainModel.submit(changed) { _ in preconditionFailure("Ambiguous POST retried") }
    precondition(uncertainBackend.calls.count == 1 && uncertainModel.requiresCreationReview)

    let changingSessions = TestSessions()
    let changingBackend = TestBackend()
    changingBackend.beforeReturn = { changingSessions.value = nil }
    let changingModel = RallySubmissionModel(sessions: changingSessions, backend: changingBackend)
    await changingModel.submit(plan) { _ in
      preconditionFailure("Shared after logout during request")
    }
    precondition(!changingModel.isSignedIn && changingModel.createdRally == nil)

    let refreshedSessions = TestSessions()
    let originalSession = refreshedSessions.value
    let suspendedBackend = SuspendedBackend()
    let refreshedModel = RallySubmissionModel(
      sessions: refreshedSessions, backend: suspendedBackend)
    refreshedModel.refreshSession()
    let pendingSubmission = Task { @MainActor in
      await refreshedModel.submit(plan) { _ in
        throw RallyIntegrationError.conversationUnavailable
      }
    }
    await suspendedBackend.waitUntilStarted()
    precondition(refreshedModel.isSubmitting)
    refreshedSessions.value = nil
    refreshedModel.refreshSession()
    precondition(!refreshedModel.isSignedIn && refreshedModel.createdRally == nil)
    refreshedSessions.value = originalSession
    refreshedModel.refreshSession()
    precondition(refreshedModel.isSignedIn)
    suspendedBackend.complete()
    await pendingSubmission.value
    precondition(refreshedModel.createdRally != nil && refreshedModel.errorMessage != nil)
    await refreshedModel.submit(plan) { _ in insertions += 1 }
    precondition(suspendedBackend.calls.count == 1, "Reauthentication discarded the saved Rally")

    let switchedSessions = TestSessions()
    let switchedBackend = SuspendedBackend()
    let switchedModel = RallySubmissionModel(sessions: switchedSessions, backend: switchedBackend)
    switchedModel.refreshSession()
    let previousAccountSubmission = Task { @MainActor in
      await switchedModel.submit(plan) { _ in
        preconditionFailure("Shared another organizer's Rally")
      }
    }
    await switchedBackend.waitUntilStarted()
    switchedSessions.value = OrganizerSession(
      userID: "another-organizer", accessToken: "test-only",
      expiresAt: Date().addingTimeInterval(3600)
    )
    switchedModel.refreshSession()
    precondition(switchedModel.isSignedIn)
    switchedBackend.complete()
    await previousAccountSubmission.value
    precondition(switchedModel.isSignedIn, "A stale submission signed out the new organizer")
    precondition(switchedModel.createdRally == nil)

    let staleAuthSessions = TestSessions()
    let staleAuthBackend = SuspendedBackend()
    let staleAuthModel = RallySubmissionModel(
      sessions: staleAuthSessions, backend: staleAuthBackend)
    staleAuthModel.refreshSession()
    let staleAuthSubmission = Task { @MainActor in
      await staleAuthModel.submit(plan) { _ in
        preconditionFailure("Shared after an authentication error")
      }
    }
    await staleAuthBackend.waitUntilStarted()
    staleAuthSessions.value = OrganizerSession(
      userID: "another-organizer", accessToken: "test-only",
      expiresAt: Date().addingTimeInterval(3600)
    )
    staleAuthModel.refreshSession()
    precondition(staleAuthModel.isSignedIn)
    staleAuthBackend.complete(error: .signInRequired)
    await staleAuthSubmission.value
    precondition(
      staleAuthModel.isSignedIn, "A stale authentication failure signed out the new organizer")
    precondition(staleAuthModel.createdRally == nil)

    let unreadableSessions = TestSessions()
    let unreadableBackend = TestBackend()
    let unreadableModel = RallySubmissionModel(
      sessions: unreadableSessions, backend: unreadableBackend)
    unreadableModel.refreshSession()
    precondition(unreadableModel.isSignedIn)
    unreadableSessions.error = .sessionUnavailable
    await unreadableModel.submit(plan) { _ in
      preconditionFailure("Shared without reading the session")
    }
    precondition(!unreadableModel.isSignedIn && unreadableBackend.calls.isEmpty)
    precondition(
      unreadableModel.errorMessage == RallyIntegrationError.sessionUnavailable.localizedDescription)

    let rejectedBackend = TestBackend()
    rejectedBackend.error = .signInRequired
    let rejectedModel = RallySubmissionModel(sessions: TestSessions(), backend: rejectedBackend)
    rejectedModel.refreshSession()
    await rejectedModel.submit(plan) { _ in
      preconditionFailure("Shared after authentication rejection")
    }
    precondition(!rejectedModel.isSignedIn && rejectedModel.createdRally == nil)
    precondition(
      rejectedModel.errorMessage == RallyIntegrationError.signInRequired.localizedDescription)

    let duplicateModel = RallySubmissionModel(sessions: TestSessions(), backend: TestBackend())
    await duplicateModel.submit(plan) { _ in
      await duplicateModel.submit(plan) { _ in preconditionFailure("Concurrent insertion") }
    }
    precondition(!duplicateModel.isSubmitting)
    try await checkHTTPContract()
    try await checkAccountContract()
    print(
      "PASS: validation, public links, session gates, API failure handling, ambiguous POST prevention, insertion retries, concurrent submission, suspended session changes"
    )
  }
}
