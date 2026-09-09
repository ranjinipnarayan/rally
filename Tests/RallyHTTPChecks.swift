import Foundation

private final class StubHTTP: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, Data))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

@MainActor
func checkHTTPContract() async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubHTTP.self]
  let transport = URLSession(configuration: configuration)
  defer { transport.invalidateAndCancel() }
  let api = RallyAPI(transport: transport)
  let session = OrganizerSession(
    userID: "test-user", accessToken: "test-jwt", expiresAt: .distantFuture)
  let date = ISO8601DateFormatter().date(from: "2099-07-10T23:00:00Z")!
  let response = Data(
    #"{"id":"saved-id","title":"Dinner","publicUrl":"https://rally-your-friends.com/r/abcdefgh23456789abcdefgh23456789","creatorToken":"private-token"}"#
      .utf8)

  for timeMode in [ScheduleMode.specific, .poll] {
    for locationMode in [LocationMode.specific, .open] {
      let plan = PlanPayload(
        activity: "Dinner", scheduleMode: timeMode,
        specificDate: timeMode == .specific ? date : nil,
        pollCandidates: timeMode == .poll ? [date] : [],
        locationMode: locationMode, location: locationMode == .specific ? "Park" : "")
      StubHTTP.handler = { request in
        precondition(request.url?.absoluteString == "https://rally-your-friends.com/api/v1/rallies")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-jwt")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var buffer = [UInt8](repeating: 0, count: 1024)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
          }
        }
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(
          Set(json.keys) == [
            "activity", "timeMode", "startsAt", "locationMode", "location", "candidates", "status",
          ])
        precondition(json["status"] as? String == "open")
        precondition(json["timeMode"] as? String == timeMode.rawValue)
        precondition(json["locationMode"] as? String == locationMode.rawValue)
        if timeMode == .specific {
          precondition(json["startsAt"] as? String == "2099-07-10T23:00:00Z")
          precondition((json["candidates"] as? [String])?.isEmpty == true)
        } else {
          precondition(json["startsAt"] is NSNull)
          precondition(json["candidates"] as? [String] == ["2099-07-10T23:00:00Z"])
        }
        if locationMode == .open {
          precondition(json["location"] is NSNull)
        } else {
          precondition(json["location"] as? String == "Park")
        }
        return (201, response)
      }
      let result = try await api.create(plan: plan, session: session)
      precondition(
        result.title == "Dinner" && !result.publicURL.absoluteString.contains("private-token"))
    }
  }

  let plan = PlanPayload(
    activity: "Dinner", scheduleMode: .specific, specificDate: date,
    pollCandidates: [], locationMode: .open, location: "")
  let draftID = "11111111-1111-4111-8111-111111111111"
  let incomplete = PlanPayload(
    activity: "", scheduleMode: .poll, specificDate: nil,
    pollCandidates: [], locationMode: .specific, location: "")
  func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 1024)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
      }
    }
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
  }
  StubHTTP.handler = { request in
    let json = try bodyJSON(request)
    precondition(request.httpMethod == "POST" && json["status"] as? String == "draft")
    precondition(json["activity"] as? String == "" && json["location"] as? String == "")
    precondition((json["candidates"] as? [String])?.isEmpty == true)
    return (201, Data("{\"id\":\"\(draftID)\"}".utf8))
  }
  let savedID = try await api.saveDraft(plan: incomplete, session: session, existingID: nil)
  precondition(savedID == draftID)
  StubHTTP.handler = { request in
    let json = try bodyJSON(request)
    precondition(request.httpMethod == "PATCH" && request.url?.lastPathComponent == draftID)
    precondition(json["action"] as? String == "save" && json["status"] == nil)
    return (200, Data("{\"rally\":{\"id\":\"\(draftID)\"}}".utf8))
  }
  _ = try await api.saveDraft(plan: incomplete, session: session, existingID: draftID)
  StubHTTP.handler = { request in
    let json = try bodyJSON(request)
    precondition(request.httpMethod == "PATCH" && json["action"] as? String == "publish")
    precondition(json["status"] == nil)
    return (
      200,
      Data(
        "{\"rally\":{\"id\":\"\(draftID)\",\"activity\":\"Dinner\",\"publicUrl\":\"https://rally-your-friends.com/r/abcdefgh23456789abcdefgh23456789\",\"status\":\"open\",\"publishedAt\":\"2026-09-09T00:00:00Z\"}}"
          .utf8)
    )
  }
  let published = try await api.publishDraft(plan: plan, session: session, id: draftID)
  precondition(published.id == draftID)
  for status in [400, 401, 409, 413, 503, 302, 200] {
    StubHTTP.handler = { _ in
      (status, Data(#"{"error":{"code":"invalid_request","message":"Check your plan."}}"#.utf8))
    }
    do {
      _ = try await api.create(plan: plan, session: session)
      preconditionFailure("HTTP error accepted")
    } catch let error as RallyIntegrationError {
      switch (status, error) {
      case (401, .signInRequired), (400, .requestRejected), (409, .requestRejected),
        (413, .requestRejected), (503, .creationUncertain), (302, .creationUncertain),
        (200, .creationUncertain):
        break
      default: preconditionFailure("Wrong error classification")
      }
    }
  }
  for body in [
    Data("not json".utf8),
    Data(
      #"{"id":"id","title":"Dinner","publicUrl":"https://rally-your-friends.com/m/abcdefgh23456789abcdefgh23456789"}"#
        .utf8),
  ] {
    StubHTTP.handler = { _ in (201, body) }
    do {
      _ = try await api.create(plan: plan, session: session)
      preconditionFailure("Invalid success accepted")
    } catch RallyIntegrationError.creationUncertain {}
  }
  StubHTTP.handler = { _ in throw URLError(.timedOut) }
  do {
    _ = try await api.create(plan: plan, session: session)
    preconditionFailure("Timeout accepted")
  } catch RallyIntegrationError.creationUncertain {}
  print(
    "PASS: HTTP contract for all four branches, explicit nulls, bearer header, public link, error and timeout handling"
  )
}

@MainActor
func checkAccountContract() async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubHTTP.self]
  let transport = URLSession(configuration: configuration)
  defer { transport.invalidateAndCancel() }
  let api = RallyAccountAPI(transport: transport)
  let id = "11111111-1111-4111-8111-111111111111"
  let detail = Data(
    #"{"rally":{"id":"11111111-1111-4111-8111-111111111111","activity":"Dinner","timeMode":"poll","startsAt":null,"locationMode":"open","location":null,"status":"open","nextAction":"choose_time","archivedAt":null,"publishedAt":"2099-07-01T12:00:00.123Z","publicUrl":"https://rally-your-friends.com/r/abcdefgh23456789abcdefgh23456789","mapsUrl":null,"finalMessage":null,"finalTime":null,"finalLocation":null,"candidates":[{"id":"option","startsAt":"2099-07-10T23:00:00+00:00"}]},"responses":[{"id":"reply","name":"Sam","consensus":"some_work","note":null,"available":["option"],"suggestions":["Park"],"timeSuggestions":["2099-07-11T23:00:00Z"]}],"creatorToken":"never-share"}"#
      .utf8)
  StubHTTP.handler = { request in
    precondition(request.httpMethod == "GET")
    precondition(request.url?.path == "/api/v1/rallies/\(id)")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-jwt")
    return (200, detail)
  }
  let decoded = try await api.detail(id: id, token: "account-jwt")
  precondition(decoded.rally.candidates.count == 1 && decoded.responses[0].available == ["option"])
  func resolvedLocation(mode: String, original: String?, final: String?) throws -> String? {
    var envelope = try JSONSerialization.jsonObject(with: detail) as! [String: Any]
    var rally = envelope["rally"] as! [String: Any]
    rally["locationMode"] = mode
    rally["location"] = original as Any? ?? NSNull()
    rally["finalLocation"] = final as Any? ?? NSNull()
    envelope["rally"] = rally
    return try RallyAccountAPI.decoder().decode(
      OrganizerDetail.self, from: JSONSerialization.data(withJSONObject: envelope)
    ).rally.resolvedLocation
  }
  let locationCases: [(String, String?, String?, String?)] = [
    ("specific", "To be decided", nil, nil),
    ("open", "Old location", nil, nil),
    ("specific", " Park ", "TO BE DECIDED", "Park"),
    ("open", nil, "  Central Park  ", "Central Park"),
  ]
  for (mode, original, final, expected) in locationCases {
    let location = try resolvedLocation(mode: mode, original: original, final: final)
    precondition(
      location == expected, "The editor must distinguish a real location from a placeholder")
  }
  for action in ["save", "confirm", "cancel", "archive", "unarchive"] {
    StubHTTP.handler = { request in
      precondition(request.httpMethod == "PATCH")
      precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
      precondition(body["action"] as? String == action)
      if action == "save" || action == "confirm" {
        precondition(body["finalTime"] is NSNull)
        precondition(body["finalLocation"] as? String == "Park")
      } else {
        precondition(body.count == 1, "Lifecycle actions must not alter choices")
      }
      return (200, detail)
    }
    _ = try await api.update(id: id, action: action, location: " Park ", token: "account-jwt")
  }
  StubHTTP.handler = { _ in throw URLError(.timedOut) }
  do {
    _ = try await api.update(id: id, action: "confirm", token: "account-jwt")
    preconditionFailure("Retried or accepted an uncertain mutation")
  } catch AccountAPIError.uncertainMutation {}

  for location in ["", "  To be decided  "] {
    StubHTTP.handler = { request in
      let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
      precondition(body["finalLocation"] is NSNull, "An undecided location must clear the override")
      return (200, detail)
    }
    _ = try await api.update(id: id, action: "save", location: location, token: "account-jwt")
  }

  var deleteCalls = 0
  StubHTTP.handler = { request in
    deleteCalls += 1
    precondition(request.httpMethod == "DELETE")
    precondition(request.url?.path == "/api/v1/rallies/\(id)")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-jwt")
    precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
    precondition(request.value(forHTTPHeaderField: "Content-Type") == nil)
    precondition(requestBody(request).isEmpty, "Deletion must not send a request body")
    return (204, Data())
  }
  try await api.delete(id: id, token: "account-jwt")
  precondition(deleteCalls == 1, "A 204 response must succeed without JSON decoding or a retry")
  do {
    try await api.delete(id: "not-a-uuid", token: "account-jwt")
    preconditionFailure("Invalid deletion ID accepted")
  } catch AccountAPIError.invalidResponse {}
  precondition(deleteCalls == 1, "An invalid ID must not reach the server")

  for status in [200, 302, 500] {
    var calls = 0
    StubHTTP.handler = { _ in
      calls += 1
      return (status, Data())
    }
    do {
      try await api.delete(id: id, token: "account-jwt")
      preconditionFailure("An ambiguous deletion response was accepted")
    } catch AccountAPIError.uncertainDeletion {}
    precondition(calls == 1, "An ambiguous deletion must not be retried automatically")
  }
  StubHTTP.handler = { _ in throw URLError(.timedOut) }
  do {
    try await api.delete(id: id, token: "account-jwt")
    preconditionFailure("A deletion timeout was accepted")
  } catch AccountAPIError.uncertainDeletion {}
  StubHTTP.handler = { _ in (404, Data()) }
  do {
    try await api.delete(id: id, token: "account-jwt")
    preconditionFailure("An unavailable Rally was accepted as a new deletion")
  } catch AccountAPIError.notFound {}
  do {
    _ = try await api.detail(id: id, token: "account-jwt")
    preconditionFailure("An unavailable Rally detail was accepted")
  } catch AccountAPIError.notFound {}
  StubHTTP.handler = { _ in (401, Data()) }
  do {
    try await api.delete(id: id, token: "expired")
    preconditionFailure("Deletion accepted an expired session")
  } catch AccountAPIError.unauthorized {}
  do {
    _ = try await api.list(token: "expired")
    preconditionFailure("Accepted an expired session")
  } catch AccountAPIError.unauthorized {}
  precondition(
    RallyAuthConfiguration.acceptsCallback(
      URL(string: "com.example.RallyMessages://auth/callback?code=test")!))
  for url in [
    "https://auth/callback", "com.example.RallyMessages://wrong/callback",
    "com.example.RallyMessages://auth/other", "com.example.RallyMessages://user@auth/callback",
  ] {
    precondition(!RallyAuthConfiguration.acceptsCallback(URL(string: url)!))
  }
  print(
    "PASS: organizer locations, timestamps, bearer authentication, PATCH fields, DELETE contract and failure recovery, uncertain mutations, callback routing"
  )
}

private func requestBody(_ request: URLRequest) -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var body = Data()
  var buffer = [UInt8](repeating: 0, count: 1024)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    body.append(contentsOf: buffer.prefix(count))
  }
  return body
}
