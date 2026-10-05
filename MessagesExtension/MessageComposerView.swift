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

struct MessageComposerView: View {
  let isExpanded: Bool
  @ObservedObject var submission: RallySubmissionModel
  let onExpand: () -> Void
  var onSignIn: () async -> Bool = { false }
  let onSendPlan: (PlanPayload) -> Void

  @State private var showSignInPrompt = false
  @State private var showOpenAppHelp = false
  @State private var showTimeZonePicker = false

  @State private var step: ComposerStep = .activity
  @State private var activity = ""
  @State private var scheduleMode: ScheduleMode = .specific
  @State private var schedule = RallySchedule()
  @State private var pollDateRange: PollDateRange = .thisWeek
  @State private var pollTimeRange: PollTimeRange = .evening
  @State private var locationMode: LocationMode = .specific
  @State private var location = ""

  private let activitySuggestions = ["Dinner", "Drinks", "Movie", "Walk", "Not sure yet"]

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
    .foregroundStyle(RallyDesign.ink)
    .tint(RallyDesign.red)
    .environment(\.colorScheme, .light)
    // Set the presentation's appearance as well as SwiftUI's environment.
    // Native date-picker labels and popovers must match our white background.
    .preferredColorScheme(.light)
    .sheet(isPresented: $showTimeZonePicker) {
      TimeZonePicker(selection: schedule.timeZone) { zone in
        schedule.changeTimeZone(to: zone)
      }
    }
    .alert(("Sign in to create your Rally").lowercased(), isPresented: $showSignInPrompt) {
      Button(("open rally").lowercased()) {
        Task { showOpenAppHelp = !(await onSignIn()) }
      }
      Button(("cancel").lowercased(), role: .cancel) {}
    } message: {
      Text(
        ("open rally to sign in. your entries will stay here while this extension remains open.")
          .lowercased())
    }
    .alert(("Open Rally from your Home Screen").lowercased(), isPresented: $showOpenAppHelp) {
      Button(("ok").lowercased(), role: .cancel) {}
    } message: {
      Text(
        ("messages couldn’t open rally. open the rally app, sign in, then return here to create your rally.")
          .lowercased())
    }
    .onChange(of: currentPayload) { _, plan in
      submission.planDidChange(plan)
    }
  }

  private var compactView: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 0) {
            Text(("rally").lowercased()).font(.title3.weight(.semibold))
            Text((".").lowercased()).font(.title3.weight(.semibold)).foregroundStyle(
              RallyDesign.red)
            RallyFinish().padding(.leading, 10)
          }
          Text(("drive the plan out of the groupchat").lowercased())
            .font(.subheadline)
          if !submission.isSignedIn {
            Text(("open rally to sign in when you’re ready to create your rally.").lowercased())
              .font(.subheadline)
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
            Button {
              moveBack()
            } label: {
              Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RallyDesign.ink)
            .accessibilityLabel("back")
          }
          Spacer()
          Text(("step \(step.rawValue + 1) of 4").lowercased())
            .font(.subheadline)
        }

        RallyJourney(step: step.rawValue)
        HStack {
          Text(step.title.lowercased()).font(.title3.weight(.semibold))
          if step == .review { RallyFinish() }
        }

        stepContent

        if step != .review, let error = submission.errorMessage {
          Text((error).lowercased()).font(.subheadline)
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
      TextField(("what do you want to do?").lowercased(), text: $activity)
        .textInputAutocapitalization(.never)
        .textInputAutocapitalization(.never)
        .textFieldStyle(RallyTextFieldStyle())

      Text(("suggestions").lowercased())
        .font(.body.weight(.semibold))

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
          if schedule.pollCandidates.isEmpty { regenerateCandidatesIfPossible() }
        }
      }

      if scheduleMode == .specific {
        VStack(spacing: 12) {
          DatePicker(
            ("date").lowercased(), selection: $schedule.specificDate, in: Date()...,
            displayedComponents: [.date]
          )
          Divider()
          DatePicker(
            ("time").lowercased(), selection: $schedule.specificDate, in: Date()...,
            displayedComponents: [.hourAndMinute]
          )
        }
        .datePickerStyle(.compact)
        .font(.subheadline)
        .padding(14)
        .background(RallyDesign.muted, in: RoundedRectangle(cornerRadius: 10))
      } else {
        pollBuilder
      }

      PrimaryButton(
        title: "Next", disabled: scheduleMode == .poll && schedule.pollCandidates.isEmpty
      ) {
        step = .location
      }

      Button {
        showTimeZonePicker = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "globe")
          Text(
            ("timezone · \(TimeZonePicker.name(for: schedule.timeZone).lowercased())").lowercased())
          Image(systemName: "chevron.right").font(.system(size: 9))
        }
        .font(.subheadline)
        .foregroundStyle(RallyDesign.secondary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("schedule-timezone")
    }
    .environment(\.timeZone, schedule.timeZone)
    .environment(\.calendar, schedule.calendar)
  }

  private var pollBuilder: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(("when — date?").lowercased())
        .font(.headline)
      FlowLayout(spacing: 8) {
        ForEach(PollDateRange.allCases) { range in
          ChoiceButton(title: range.rawValue, selected: pollDateRange == range) {
            pollDateRange = range
            regenerateCandidatesIfPossible()
          }
        }
      }

      Text(("when — time-wise?").lowercased())
        .font(.headline)
      FlowLayout(spacing: 8) {
        ForEach(PollTimeRange.allCases) { range in
          ChoiceButton(title: range.rawValue, selected: pollTimeRange == range) {
            pollTimeRange = range
            regenerateCandidatesIfPossible()
          }
        }
      }

      if !schedule.pollCandidates.isEmpty {
        Text(("edit the candidates").lowercased())
          .font(.headline)
        ForEach($schedule.pollCandidates) { $candidate in
          HStack {
            DatePicker(
              ("Option \((schedule.pollCandidates.firstIndex { $0.id == candidate.id } ?? 0) + 1)")
                .lowercased(),
              selection: $candidate.date,
              in: Date()...,
              displayedComponents: [.date, .hourAndMinute]
            )
            .foregroundStyle(Color.primary)
            .tint(RallyDesign.red)
            Button {
              schedule.pollCandidates.removeAll { $0.id == candidate.id }
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel(
              "Remove option \((schedule.pollCandidates.firstIndex { $0.id == candidate.id } ?? 0) + 1)"
            )
          }
        }
      }
      Button(("regenerate 3 options").lowercased()) {
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
        LocationAutocompleteField(title: "Location", text: $location, cornerRadius: 6)
      }

      PrimaryButton(title: "Review") {
        step = .review
      }
    }
  }

  private var reviewStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      RallyPlanCard {
        VStack(alignment: .leading, spacing: 14) {
          ReviewRow(label: "Plan", value: resolvedActivity)
          ReviewRow(label: scheduleMode == .poll ? "when (poll)" : "when", value: scheduleSummary)
          ReviewRow(
            label: "Where", value: locationMode == .specific ? resolvedLocation : "Choose later")

        }
      }.padding(.vertical, 10)

      Divider().overlay(RallyDesign.border)

      if let error = submission.errorMessage {
        Text((error).lowercased()).font(.subheadline)
      }
      if submission.requiresCreationReview {
        Link(
          ("review my rallies").lowercased(),
          destination: URL(string: "https://rally-your-friends.com/my-rallies")!
        )
        .font(.headline)
      }
      if submission.createdRally != nil {
        Text(("rally saved. add its link to your conversation.").lowercased()).font(.subheadline)
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
      specificDate: scheduleMode == .specific ? schedule.specificDate : nil,
      pollCandidates: scheduleMode == .poll ? schedule.pollCandidates.map(\.date) : [],
      locationMode: locationMode,
      location: locationMode == .specific ? resolvedLocation : "",
      timeZone: schedule.timeZone
    )
  }

  private var scheduleSummary: String {
    scheduleSummary(for: currentPayload)
  }

  private func scheduleSummary(for plan: PlanPayload) -> String {
    if let date = plan.specificDate {
      return reviewDate(date)
    }
    return plan.pollCandidates
      .map { reviewDate($0) }
      .joined(separator: "\n")
  }

  private func reviewDate(_ date: Date) -> String {
    let zone = schedule.timeZone.abbreviation(for: date) ?? schedule.timeZone.identifier
    return "\(schedule.formatted(date)) \(zone)"
  }

  private func moveBack() {
    guard let previousStep = ComposerStep(rawValue: step.rawValue - 1) else { return }
    step = previousStep
  }

  private func regenerateCandidatesIfPossible() {
    schedule.regenerateCandidates(dateRange: pollDateRange, timeRange: pollTimeRange)
  }
}

private struct PrimaryButton: View {
  let title: String
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title.lowercased())
    }
    .buttonStyle(RallyActionButtonStyle())
    .disabled(disabled)
  }
}

private struct ChoiceButton: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title.lowercased())
        .font(.subheadline)
        .foregroundStyle(selected ? Color.white : RallyDesign.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? RallyDesign.ink : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RallyDesign.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
  }
}

private struct ReviewRow: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.lowercased())
        .font(.body.weight(.semibold))
      Text(value.lowercased())
        .font(.body)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
