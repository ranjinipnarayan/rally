import Foundation

private func plan(_ overrides: [String: Any] = [:]) throws -> OrganizerDetail.Plan {
  var fields: [String: Any] = [
    "id": "11111111-1111-4111-8111-111111111111",
    "activity": "Dinner",
    "timeMode": "poll",
    "startsAt": "2026-11-02T18:00:00Z",
    "locationMode": "specific",
    "location": "Original restaurant",
    "status": "confirmed",
    "nextAction": "none",
    "publishedAt": "2026-09-09T12:00:00Z",
    "publicUrl": "https://rally-your-friends.com/r/abcdefgh23456789abcdefgh23456789",
    "finalMessage": "Dinner at the new restaurant!",
    "finalTime": "2026-11-03T19:30:00-05:00",
    "finalLocation": "  New restaurant  ",
    "candidates": [["id": "option", "startsAt": "2026-11-02T18:00:00Z"]],
  ]
  fields.merge(overrides) { _, value in value }
  return try RallyAccountAPI.decoder().decode(
    OrganizerDetail.Plan.self, from: JSONSerialization.data(withJSONObject: fields))
}

@main
struct RallyCalendarChecks {
  static func main() throws {
    // The locked choices must win over the original time, place, and poll candidates.
    let confirmed = try plan()
    let event = RallyCalendarEvent(plan: confirmed)!
    let formatter = ISO8601DateFormatter()
    precondition(event.title == "Dinner")
    precondition(event.startDate == formatter.date(from: "2026-11-04T00:30:00Z"))
    precondition(event.endDate == formatter.date(from: "2026-11-04T01:30:00Z"))
    precondition(event.location == "New restaurant")
    precondition(event.url == confirmed.publicUrl)
    precondition(event.notes == confirmed.finalMessage)

    // Tentative, unpublished, cancelled, and completed plans cannot start this flow.
    for status in ["draft", "open", "cancelled", "completed", "unknown"] {
      let value = try plan(["status": status])
      precondition(RallyCalendarEvent(plan: value) == nil)
    }
    let unpublished = try plan(["publishedAt": NSNull()])
    precondition(RallyCalendarEvent(plan: unpublished) == nil)
    let missingTime = try plan(["finalTime": NSNull(), "startsAt": NSNull()])
    precondition(RallyCalendarEvent(plan: missingTime) == nil)

    // Fixed plans can retain their original details; no arbitrary time is invented.
    let fixed = try plan([
      "timeMode": "specific", "finalTime": NSNull(), "finalLocation": NSNull(),
    ])
    let fixedEvent = RallyCalendarEvent(plan: fixed)!
    precondition(fixedEvent.startDate == fixed.startsAt)
    precondition(fixedEvent.location == "Original restaurant")

    let undecided = try plan([
      "locationMode": "open", "finalLocation": "To be decided", "finalMessage": NSNull(),
    ])
    let undecidedEvent = RallyCalendarEvent(plan: undecided)!
    precondition(undecidedEvent.location == nil && undecidedEvent.notes == nil)

    // A one-hour event remains one hour when the clock changes for daylight saving.
    let clockChange = try plan(["finalTime": "2026-11-01T01:30:00-04:00"])
    let clockChangeEvent = RallyCalendarEvent(plan: clockChange)!
    precondition(clockChangeEvent.startDate == formatter.date(from: "2026-11-01T05:30:00Z"))
    precondition(clockChangeEvent.endDate == formatter.date(from: "2026-11-01T06:30:00Z"))

    print("Rally calendar checks passed")
  }
}
