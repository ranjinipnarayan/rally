import Foundation

enum PollDateRange: String, CaseIterable, Identifiable {
  case thisWeek = "This week"
  case thisWeekend = "This weekend"
  case nextWeek = "Next week"

  var id: String { rawValue }
}

enum PollTimeRange: String, CaseIterable, Identifiable {
  case morning = "Morning"
  case afternoon = "Afternoon"
  case evening = "Evening"

  var id: String { rawValue }

  var hour: Int {
    switch self {
    case .morning: 10
    case .afternoon: 14
    case .evening: 19
    }
  }
}

struct PollCandidate: Identifiable {
  let id = UUID()
  var date: Date
}

struct RallySchedule {
  private(set) var timeZone: TimeZone
  var specificDate: Date
  var pollCandidates: [PollCandidate] = []

  init(timeZone: TimeZone = .current, now: Date = Date()) {
    self.timeZone = timeZone
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
    specificDate =
      calendar.date(bySettingHour: 19, minute: 0, second: 0, of: tomorrow) ?? tomorrow
  }

  var calendar: Calendar {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return calendar
  }

  mutating func changeTimeZone(to newTimeZone: TimeZone) {
    guard newTimeZone != timeZone else { return }
    let oldCalendar = calendar
    var newCalendar = oldCalendar
    newCalendar.timeZone = newTimeZone
    func keepingClockTime(_ date: Date) -> Date {
      let components = oldCalendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second], from: date)
      // Calendar resolves nonexistent spring-forward times to the next valid time.
      return newCalendar.date(from: components) ?? date
    }
    specificDate = keepingClockTime(specificDate)
    for index in pollCandidates.indices {
      pollCandidates[index].date = keepingClockTime(pollCandidates[index].date)
    }
    timeZone = newTimeZone
  }

  func formatted(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  mutating func regenerateCandidates(
    dateRange: PollDateRange, timeRange: PollTimeRange, now: Date = Date()
  ) {
    let calendar = calendar
    let startOfToday = calendar.startOfDay(for: now)
    let candidateDays: [Date]

    switch dateRange {
    case .thisWeek:
      candidateDays = (1...3).compactMap {
        calendar.date(byAdding: .day, value: $0, to: startOfToday)
      }
    case .thisWeekend:
      let weekday = calendar.component(.weekday, from: now)
      let daysUntilFriday = (6 - weekday + 7) % 7
      let offset = daysUntilFriday == 0 ? 7 : daysUntilFriday
      candidateDays = (offset...(offset + 2)).compactMap {
        calendar.date(byAdding: .day, value: $0, to: startOfToday)
      }
    case .nextWeek:
      let nextMonday =
        calendar.nextDate(
          after: startOfToday,
          matching: DateComponents(weekday: 2),
          matchingPolicy: .nextTime
        ) ?? startOfToday
      candidateDays = [0, 2, 4].compactMap {
        calendar.date(byAdding: .day, value: $0, to: nextMonday)
      }
    }

    pollCandidates = candidateDays.compactMap { day in
      calendar.date(bySettingHour: timeRange.hour, minute: 0, second: 0, of: day)
    }.map { PollCandidate(date: $0) }
  }
}
