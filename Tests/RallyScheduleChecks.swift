import Foundation

@main
struct RallyScheduleChecks {
  static func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  static func main() {
    let newYork = TimeZone(identifier: "America/New_York")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
    let utc = TimeZone(identifier: "Etc/UTC")!
    let now = date("2026-09-29T02:00:00Z")
    let initial = RallySchedule(now: now)
    precondition(initial.timeZone == .current, "New plans must use the phone's timezone")
    precondition(initial.calendar.timeZone == initial.timeZone)
    precondition(initial.calendar.component(.hour, from: initial.specificDate) == 19)

    // At this instant New York and Kathmandu are on different calendar days.
    let west = RallySchedule(timeZone: newYork, now: now)
    let east = RallySchedule(timeZone: kathmandu, now: now)
    precondition(west.specificDate == date("2026-09-29T23:00:00Z"))
    precondition(east.specificDate == date("2026-09-30T13:15:00Z"))

    var schedule = RallySchedule(timeZone: newYork, now: now)
    schedule.specificDate = date("2027-01-16T00:00:00Z")  // January 15, 7 PM in New York.
    schedule.pollCandidates = [
      PollCandidate(date: schedule.specificDate),
      PollCandidate(date: date("2027-07-15T23:00:00Z")),
    ]
    let ids = schedule.pollCandidates.map(\.id)
    let originalSummary = schedule.formatted(schedule.specificDate)
    schedule.changeTimeZone(to: losAngeles)
    precondition(schedule.specificDate == date("2027-01-16T03:00:00Z"))
    precondition(
      schedule.pollCandidates.map(\.date) == [
        date("2027-01-16T03:00:00Z"), date("2027-07-16T02:00:00Z"),
      ])
    precondition(schedule.pollCandidates.map(\.id) == ids, "Keep edited poll options")
    precondition(schedule.formatted(schedule.specificDate) == originalSummary)
    schedule.changeTimeZone(to: kathmandu)
    precondition(schedule.specificDate == date("2027-01-15T13:15:00Z"))
    precondition(schedule.formatted(schedule.specificDate) == originalSummary)
    schedule.changeTimeZone(to: kathmandu)
    precondition(schedule.specificDate == date("2027-01-15T13:15:00Z"))

    // Regeneration uses the selected zone's day and local morning/afternoon/evening.
    for zone in [newYork, kathmandu] {
      for range in PollDateRange.allCases {
        for time in PollTimeRange.allCases {
          var poll = RallySchedule(timeZone: zone, now: now)
          poll.regenerateCandidates(dateRange: range, timeRange: time, now: now)
          precondition(poll.pollCandidates.count == 3)
          for candidate in poll.pollCandidates {
            precondition(candidate.date > now)
            precondition(poll.calendar.component(.hour, from: candidate.date) == time.hour)
            precondition(poll.calendar.component(.minute, from: candidate.date) == 0)
          }
        }
      }
    }
    var poll = RallySchedule(timeZone: kathmandu, now: now)
    poll.regenerateCandidates(dateRange: .thisWeek, timeRange: .evening, now: now)
    precondition(poll.pollCandidates.first?.date == date("2026-09-30T13:15:00Z"))
    poll.changeTimeZone(to: newYork)
    poll.regenerateCandidates(
      dateRange: .thisWeek, timeRange: .evening, now: date("2027-03-12T17:00:00Z"))
    precondition(
      poll.pollCandidates.map(\.date) == [
        date("2027-03-14T00:00:00Z"), date("2027-03-14T23:00:00Z"),
        date("2027-03-15T23:00:00Z"),
      ], "Poll times must stay at 7 PM across spring daylight saving")
    poll.regenerateCandidates(
      dateRange: .thisWeek, timeRange: .evening, now: date("2027-11-05T12:00:00Z"))
    precondition(
      poll.pollCandidates[1].date.timeIntervalSince(poll.pollCandidates[0].date) == 90000)

    var gap = RallySchedule(timeZone: utc, now: now)
    gap.specificDate = date("2027-03-14T02:30:00Z")
    gap.changeTimeZone(to: newYork)
    precondition(
      gap.specificDate == date("2027-03-14T07:30:00Z"), "Resolve skipped 2:30 AM to 3:30 AM")
    var repeated = RallySchedule(timeZone: utc, now: now)
    repeated.specificDate = date("2027-11-07T01:30:00Z")
    repeated.changeTimeZone(to: newYork)
    precondition(
      repeated.specificDate == date("2027-11-07T05:30:00Z"), "Use the first repeated 1:30 AM")

    print(
      "PASS: phone timezone default, clock-time preservation, review formatting, poll generation, fractional offsets, and daylight saving"
    )
  }
}
