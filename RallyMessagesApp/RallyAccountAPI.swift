import Foundation

struct RallyAccount: Decodable {
  let id: String
  let email: String?
}

struct OrganizerRally: Decodable, Identifiable {
  let id: String
  let activity: String
  let publicUrl: URL
  let time: Date?
  let location: String?
  let status: String
  let nextAction: String
  let section: String
  let archivedAt: Date?
  let responseCount: Int
}

struct OrganizerDetail: Decodable {
  struct Plan: Decodable, Identifiable {
    let id: String
    let activity: String
    let timeMode: String
    let startsAt: Date?
    let locationMode: String
    let location: String?
    let status: String
    let nextAction: String
    let archivedAt: Date?
    let publishedAt: Date?
    let publicUrl: URL
    let mapsUrl: URL?
    let finalMessage: String?
    let finalTime: Date?
    let finalLocation: String?
    let candidates: [Candidate]

    var resolvedLocation: String? {
      RallyLocation.value(finalLocation)
        ?? (locationMode == "specific" ? RallyLocation.value(location) : nil)
    }
  }
  struct Candidate: Decodable, Identifiable {
    let id: String
    let startsAt: Date
  }
  struct Response: Decodable, Identifiable {
    let id: String
    let name: String
    let consensus: String?
    let note: String?
    let available: [String]
    let suggestions: [String]
    let timeSuggestions: [Date]
  }
  let rally: Plan
  let responses: [Response]
}

enum RallyLabels {
  static func status(_ value: String) -> String {
    [
      "draft": "Draft", "open": "Open", "confirmed": "Confirmed",
      "cancelled": "Cancelled", "completed": "Completed",
    ][value] ?? value.capitalized
  }
  static func nextAction(_ value: String) -> String {
    [
      "waiting_for_responses": "Waiting for responses", "choose_time": "Choose time",
      "choose_location": "Choose location", "finalize": "Finalize", "none": "None",
    ][value] ?? value
  }
  static func response(_ value: String?) -> String {
    guard let value else { return "Responded" }
    return [
      "yes": "Yes", "no": "No", "another_day": "Please choose another day",
      "some_work": "Some times work", "none_work": "None of these work",
    ][value] ?? value
  }
}

enum AccountAPIError: LocalizedError {
  case unauthorized, invalidResponse, notFound
  case server(String)
  case uncertainMutation
  case uncertainDeletion
  var errorDescription: String? {
    switch self {
    case .unauthorized: "Your session expired. Please sign in again."
    case .invalidResponse: "Rally returned an unexpected response. Please refresh."
    case .notFound: "This Rally is no longer available in your account."
    case .server(let message): message
    case .uncertainMutation:
      "The change may have saved. Refresh this Rally to check before trying again."
    case .uncertainDeletion:
      "The Rally may have been deleted. Refresh to check before trying again."
    }
  }
}

struct RallyAccountAPI {
  private let transport: URLSession
  private let baseURL = URL(string: "https://rally-your-friends.com/api/v1")!

  init(transport: URLSession? = nil) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    self.transport = transport ?? URLSession(configuration: configuration)
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { value in
      let container = try value.singleValueContainer()
      let string = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: string) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: string) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
    }
    return decoder
  }

  func me(token: String) async throws -> RallyAccount {
    struct Envelope: Decodable { let user: RallyAccount }
    let envelope: Envelope = try await request(path: "me", token: token)
    return envelope.user
  }

  func list(token: String) async throws -> [OrganizerRally] {
    struct Envelope: Decodable { let rallies: [OrganizerRally] }
    let envelope: Envelope = try await request(path: "rallies", token: token)
    return envelope.rallies
  }

  func detail(id: String, token: String) async throws -> OrganizerDetail {
    guard UUID(uuidString: id) != nil else { throw AccountAPIError.invalidResponse }
    return try await request(path: "rallies/\(id)", token: token)
  }

  func update(
    id: String, action: String, time: Date? = nil, location: String? = nil,
    token: String
  ) async throws -> OrganizerDetail {
    guard UUID(uuidString: id) != nil else { throw AccountAPIError.invalidResponse }
    var body: [String: Any] = ["action": action]
    if action == "save" || action == "confirm" {
      body["finalTime"] = time.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
      body["finalLocation"] =
        RallyLocation.value(location) as Any? ?? NSNull()
    }
    return try await request(
      path: "rallies/\(id)", token: token,
      body: JSONSerialization.data(withJSONObject: body))
  }

  func delete(id: String, token: String) async throws {
    guard UUID(uuidString: id) != nil else { throw AccountAPIError.invalidResponse }
    do {
      _ = try await requestData(
        path: "rallies/\(id)", token: token, method: "DELETE", successStatus: 204)
    } catch AccountAPIError.uncertainMutation {
      throw AccountAPIError.uncertainDeletion
    }
  }

  private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  struct Failure: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
  }

  private func request<T: Decodable>(path: String, token: String, body: Data? = nil) async throws
    -> T
  {
    let data = try await requestData(
      path: path, token: token, method: body == nil ? "GET" : "PATCH", body: body)
    do { return try Self.decoder().decode(T.self, from: data) } catch {
      throw body == nil ? AccountAPIError.invalidResponse : AccountAPIError.uncertainMutation
    }
  }

  private func requestData(
    path: String, token: String, method: String, body: Data? = nil, successStatus: Int = 200
  ) async throws -> Data {
    let isMutation = method != "GET"
    var request = URLRequest(
      url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await transport.data(for: request, delegate: NoRedirect()) } catch {
      if isMutation { throw AccountAPIError.uncertainMutation }
      throw error
    }
    guard let http = response as? HTTPURLResponse else {
      throw isMutation ? AccountAPIError.uncertainMutation : AccountAPIError.invalidResponse
    }
    if http.statusCode == 401 { throw AccountAPIError.unauthorized }
    if http.statusCode == 404 { throw AccountAPIError.notFound }
    guard http.statusCode == successStatus else {
      if isMutation && (http.statusCode >= 500 || (200..<400).contains(http.statusCode)) {
        throw AccountAPIError.uncertainMutation
      }
      let failure = try? JSONDecoder().decode(Failure.self, from: data)
      throw AccountAPIError.server(
        failure?.error.message ?? "Couldn’t load this Rally. Please refresh.")
    }
    return data
  }
}
