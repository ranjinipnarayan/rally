import Foundation

struct RallyCalendarEvent: Identifiable {
  let id: String
  let title: String
  let startDate: Date
  let endDate: Date
  let location: String?
  let url: URL
  let notes: String?

  init?(plan: OrganizerDetail.Plan) {
    guard plan.status == "confirmed", plan.publishedAt != nil,
      let startDate = plan.finalTime ?? plan.startsAt
    else { return nil }

    id = plan.id
    let activity = plan.activity.trimmingCharacters(in: .whitespacesAndNewlines)
    title = activity.isEmpty ? "Rally" : activity
    self.startDate = startDate
    // Rally has no end time; people can adjust this duration in the calendar editor.
    endDate = startDate.addingTimeInterval(60 * 60)
    location = plan.resolvedLocation
    url = plan.publicUrl
    notes = plan.finalMessage
  }
}
