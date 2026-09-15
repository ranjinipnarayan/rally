import SwiftUI

private enum ComposerStep: Int {
  case activity
  case schedule
  case location
  case review

  var title: String {
    switch self {
    case .activity: "1. What are you planning?"
    case .schedule: "2. When?"
    case .location: "3. Where?"
    case .review: "Review"
    }
  }
}

private enum PollDateRange: String, CaseIterable, Identifiable {
  case thisWeek = "This week"
  case thisWeekend = "This weekend"
  case nextWeek = "Next week"

  var id: String { rawValue }
}

private enum PollTimeRange: String, CaseIterable, Identifiable {
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

private struct PollCandidate: Identifiable {
  let id = UUID()
  var date: Date
}

struct MessageComposerView: View {
  let isExpanded: Bool
  @ObservedObject var submission: RallySubmissionModel
  let onExpand: () -> Void
  var onSignIn: () async -> Bool = { false }
  let onSendPlan: (PlanPayload) -> Void

  @State private var showSignInPrompt = false
  @State private var showOpenAppHelp = false

  @State private var step: ComposerStep = .activity
  @State private var activity = ""
  @State private var scheduleMode: ScheduleMode = .specific
  @State private var specificDate: Date = {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: tomorrow) ?? tomorrow
  }()
  @State private var pollDateRange: PollDateRange = .thisWeek
  @State private var pollTimeRange: PollTimeRange = .evening
  @State private var pollCandidates: [PollCandidate] = []
  @State private var locationMode: LocationMode = .specific
  @State private var location = ""

  private let activitySuggestions = ["Dinner", "Coffee", "Drinks", "Movie", "Walk", "Not sure yet"]

  var body: some View {
    Group {
      if isExpanded {
        composerView
      } else {
        compactView
      }
    }
    .disabled(submission.isSubmitting)
    .padding(16)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .tint(.black)
    .environment(\.colorScheme, .light)
    // Set the presentation's appearance as well as SwiftUI's environment.
    // Native date-picker labels and popovers must match our white background.
    .preferredColorScheme(.light)
    .alert("Sign in to create your Rally", isPresented: $showSignInPrompt) {
      Button("Open Rally") {
        Task { showOpenAppHelp = !(await onSignIn()) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Open Rally to sign in. Your entries will stay here while this extension remains open.")
    }
    .alert("Open Rally from your Home Screen", isPresented: $showOpenAppHelp) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        "Messages couldn’t open Rally. Open the Rally app, sign in, then return here to create your Rally."
      )
    }
    .onChange(of: currentPayload) { _, plan in
      submission.planDidChange(plan)
    }
  }

  private var compactView: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Rally")
            .font(.headline)
          Text("Drive the plan out of the groupchat")
            .font(.subheadline)
          if !submission.isSignedIn {
            Text("Open Rally to sign in when you’re ready to create your Rally.")
              .font(.caption)
          }
          PrimaryButton(title: "Create a plan", action: onExpand)
        }
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  private var composerView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          if step != .activity {
            Button("Back") {
              moveBack()
            }
            .foregroundStyle(.black)
          }
          Spacer()
          Text("Step \(step.rawValue + 1) of 4")
            .font(.caption)
        }

        Text(step.title)
          .font(.title2.bold())

        stepContent

        if step != .review, let error = submission.errorMessage {
          Text(error).font(.caption)
        }
      }
    }
  }

  @ViewBuilder
  private var stepContent: some View {
    switch step {
    case .activity:
      activityStep
    case .schedule:
      scheduleStep
    case .location:
      locationStep
    case .review:
      reviewStep
    }
  }

  private var activityStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      TextField("What do you want to do?", text: $activity)
        .textFieldStyle(PlainBlackTextFieldStyle())

      Text("Suggestions")
        .font(.subheadline.bold())

      FlowLayout(spacing: 8) {
        ForEach(activitySuggestions, id: \.self) { suggestion in
          ChoiceButton(
            title: suggestion,
            selected: activity == (suggestion == "Not sure yet" ? "Let's hang out" : suggestion)
          ) {
            activity = suggestion == "Not sure yet" ? "Let's hang out" : suggestion
          }
        }
      }

      PrimaryButton(title: "Next") {
        step = .schedule
      }
    }
  }

  private var scheduleStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        ChoiceButton(title: "Specific date and time", selected: scheduleMode == .specific) {
          scheduleMode = .specific
        }
        ChoiceButton(title: "Create a poll", selected: scheduleMode == .poll) {
          scheduleMode = .poll
          if pollCandidates.isEmpty { regenerateCandidatesIfPossible() }
        }
      }

      if scheduleMode == .specific {
        DatePicker(
          "Date and time",
          selection: $specificDate,
          in: Date()...,
          displayedComponents: [.date, .hourAndMinute]
        )
        .datePickerStyle(.graphical)
        .foregroundStyle(Color.primary)
        .tint(.black)
      } else {
        pollBuilder
      }

      PrimaryButton(title: "Next", disabled: scheduleMode == .poll && pollCandidates.isEmpty) {
        step = .location
      }
    }
  }

  private var pollBuilder: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("When — date?")
        .font(.headline)
      FlowLayout(spacing: 8) {
        ForEach(PollDateRange.allCases) { range in
          ChoiceButton(title: range.rawValue, selected: pollDateRange == range) {
            pollDateRange = range
            regenerateCandidatesIfPossible()
          }
        }
      }

      Text("When — time-wise?")
        .font(.headline)
      FlowLayout(spacing: 8) {
        ForEach(PollTimeRange.allCases) { range in
          ChoiceButton(title: range.rawValue, selected: pollTimeRange == range) {
            pollTimeRange = range
            regenerateCandidatesIfPossible()
          }
        }
      }

      if !pollCandidates.isEmpty {
        Text("Edit the candidates")
          .font(.headline)
        ForEach($pollCandidates) { $candidate in
          HStack {
            DatePicker(
              "Option \((pollCandidates.firstIndex { $0.id == candidate.id } ?? 0) + 1)",
              selection: $candidate.date,
              in: Date()...,
              displayedComponents: [.date, .hourAndMinute]
            )
            .foregroundStyle(Color.primary)
            .tint(.black)
            Button {
              pollCandidates.removeAll { $0.id == candidate.id }
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel(
              "Remove option \((pollCandidates.firstIndex { $0.id == candidate.id } ?? 0) + 1)")
          }
        }
      }
      Button("Regenerate 3 options") {
        regenerateCandidatesIfPossible()
      }
    }
  }

  private var locationStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 8) {
        ChoiceButton(title: "Specific location", selected: locationMode == .specific) {
          locationMode = .specific
        }
        ChoiceButton(title: "Leave open", selected: locationMode == .open) {
          locationMode = .open
        }
      }

      if locationMode == .specific {
        LocationAutocompleteField(title: "Location", text: $location, cornerRadius: 0)
      }

      PrimaryButton(title: "Review") {
        step = .review
      }
    }
  }

  private var reviewStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      ReviewRow(label: "Plan", value: resolvedActivity)
      ReviewRow(label: "When", value: scheduleSummary)
      ReviewRow(
        label: "Where", value: locationMode == .specific ? resolvedLocation : "Choose later")
      ReviewRow(label: "Response", value: routeSummary)

      Divider().overlay(Color.black)

      if let error = submission.errorMessage {
        Text(error).font(.caption)
      }
      if submission.requiresCreationReview {
        Link(
          "Review My Rallies",
          destination: URL(string: "https://rally-your-friends.com/my-rallies")!
        )
        .font(.headline)
      }
      if submission.createdRally != nil {
        Text("Rally saved. Add its link to your conversation.").font(.caption)
      }
      PrimaryButton(
        title: submission.isSubmitting
          ? "Creating…" : (submission.createdRally == nil ? "Create Rally" : "Add link to message"),
        disabled: submission.isSubmitting || submission.requiresCreationReview
      ) {
        submission.refreshSession()
        if submission.isSignedIn {
          onSendPlan(currentPayload)
        } else {
          showSignInPrompt = true
        }
      }
    }
  }

  private var resolvedActivity: String {
    let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
    let unknownAnswers = ["i don't know", "i dont know", "idk", "not sure", "dunno", "no idea"]
    return trimmed.isEmpty || unknownAnswers.contains(trimmed.lowercased())
      ? "Let's hang out" : trimmed
  }

  private var resolvedLocation: String {
    let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "To be decided" : trimmed
  }

  private var currentPayload: PlanPayload {
    PlanPayload(
      activity: resolvedActivity,
      scheduleMode: scheduleMode,
      specificDate: scheduleMode == .specific ? specificDate : nil,
      pollCandidates: scheduleMode == .poll ? pollCandidates.map(\.date) : [],
      locationMode: locationMode,
      location: locationMode == .specific ? resolvedLocation : ""
    )
  }

  private var scheduleSummary: String {
    scheduleSummary(for: currentPayload)
  }

  private func scheduleSummary(for plan: PlanPayload) -> String {
    if let date = plan.specificDate {
      return date.formatted(date: .abbreviated, time: .shortened)
    }
    return plan.pollCandidates
      .map { $0.formatted(date: .abbreviated, time: .shortened) }
      .joined(separator: "\n")
  }

  private var routeSummary: String {
    switch (scheduleMode, locationMode) {
    case (.specific, .specific):
      "Yes / No / Please choose another day"
    case (.specific, .open):
      "Consensus, then location suggestions"
    case (.poll, .specific):
      "Time poll with the fixed location"
    case (.poll, .open):
      "Time poll, then location suggestions"
    }
  }

  private func moveBack() {
    guard let previousStep = ComposerStep(rawValue: step.rawValue - 1) else { return }
    step = previousStep
  }

  private func regenerateCandidatesIfPossible() {
    pollCandidates = Self.generateCandidates(dateRange: pollDateRange, timeRange: pollTimeRange)
      .map { PollCandidate(date: $0) }
  }

  private static func generateCandidates(dateRange: PollDateRange, timeRange: PollTimeRange)
    -> [Date]
  {
    let calendar = Calendar.current
    let now = Date()
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

    return candidateDays.compactMap { day in
      calendar.date(bySettingHour: timeRange.hour, minute: 0, second: 0, of: day)
    }
  }
}

private struct PrimaryButton: View {
  let title: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(disabled ? Color.black.opacity(0.35) : Color.black)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }
}

private struct ChoiceButton: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline)
        .foregroundStyle(selected ? Color.white : Color.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.black : Color.white)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }
    .buttonStyle(.plain)
  }
}

private struct ReviewRow: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption.bold())
      Text(value)
        .font(.body)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct PlainBlackTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .padding(12)
      .foregroundStyle(Color.black)
      .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = layout(proposal: proposal, subviews: subviews)
    for (index, point) in result.points.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (
    size: CGSize, points: [CGPoint]
  ) {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var points: [CGPoint] = []

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }

    return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), points)
  }
}

#if DEBUG
  private struct PreviewOrganizerSession: OrganizerSessionProviding {
    func session() throws -> OrganizerSession? {
      OrganizerSession(
        userID: "preview-only", accessToken: "preview-only", expiresAt: .distantFuture
      )
    }
  }

  struct MessageComposerView_Previews: PreviewProvider {
    private static var signedInModel: RallySubmissionModel {
      let model = RallySubmissionModel(sessions: PreviewOrganizerSession())
      model.refreshSession()
      return model
    }

    static var previews: some View {
      MessageComposerView(
        isExpanded: true,
        submission: RallySubmissionModel(),
        onExpand: {},
        onSendPlan: { _ in }
      )
      .previewDisplayName("Signed out")

      MessageComposerView(
        isExpanded: true,
        submission: signedInModel,
        onExpand: {},
        onSendPlan: { _ in }
      )
      .previewDisplayName("Create a Rally")
    }
  }
#endif
