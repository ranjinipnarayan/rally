import SwiftUI

struct ContentView: View {
  @ObservedObject var model: RallyAccountModel
  @State private var email = ""
  @State private var code = ""
  @State private var isShowingLogin = false
  @State private var rallyToDelete: OrganizerRally?
  @State private var showDeleteConfirmation = false
  @State private var showDeleteError = false
  @State private var deleteError = ""

  var body: some View {
    NavigationStack {
      Group {
        if model.loading {
          ProgressView("loading rally…")
        } else if model.account == nil {
          welcome
            .toolbar(.hidden, for: .navigationBar)
        } else {
          dashboard
        }
      }
      .navigationTitle(("rally").lowercased())
      .navigationDestination(isPresented: $isShowingLogin) {
        login
          .navigationBarTitleDisplayMode(.inline)
          .toolbar(.visible, for: .navigationBar)
      }
    }
    .id(model.account?.id)
    .tint(RallyDesign.red)
    .foregroundStyle(RallyDesign.ink)
    .preferredColorScheme(.light)
    .onChange(of: model.isEnteringCode) { _, _ in code = "" }
    .onChange(of: model.signInEmail) { _, sentEmail in
      if let sentEmail { email = sentEmail }
    }
    .onChange(of: model.account?.id) { _, _ in
      email = ""
      code = ""
      isShowingLogin = false
      rallyToDelete = nil
      showDeleteConfirmation = false
      showDeleteError = false
      deleteError = ""
    }
    .onOpenURL { url in
      if RallyAuthConfiguration.acceptsCallback(url) {
        if model.account == nil { isShowingLogin = true }
        Task { await model.handleCallback(url) }
      } else if url.scheme?.lowercased() == "com.example.rallymessages", url.host == "signin" {
        if model.account == nil { isShowingLogin = true }
        Task { await model.refresh() }
      }
    }
  }

  private var welcome: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack {
          Text(("rally").lowercased()).font(.system(size: 28, weight: .semibold))
          Text((".").lowercased()).font(.system(size: 28, weight: .semibold)).foregroundStyle(
            RallyDesign.red)
          RallyFinish()
        }
        Text(("how to create a rally").lowercased()).font(.title3.weight(.semibold))
        creationStep(
          1, title: "Open Messages",
          detail: "Choose a conversation with a friend or group.")
        creationStep(
          2, title: "Tap + and choose Rally",
          detail: "Find Rally in the apps for your conversation.")
        messagesAppGuide
          .padding(.leading, 36)
        creationStep(
          3, title: "Make your plan",
          detail: "Choose what, when, and where. Then send your Rally to the conversation.")
        Button(("see your rallies").lowercased()) { isShowingLogin = true }
          .buttonStyle(RallyActionButtonStyle())
        RallyAppShareFooter()
      }
      .padding(24)
    }
  }

  private func creationStep(_ number: Int, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(("\(number).").lowercased())
        .font(.headline)
        .frame(width: 24, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        Text(title.lowercased()).font(.headline)
        Text(detail.lowercased()).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var messagesAppGuide: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "plus")
          .font(.system(size: 20, weight: .medium))
          .frame(width: 38, height: 38)
          .background(.white, in: Circle())
          .overlay(Circle().stroke(RallyDesign.red, lineWidth: 2))
        HStack {
          Text("imessage").font(.subheadline).foregroundStyle(RallyDesign.secondary)
          Spacer()
          Image(systemName: "mic.fill").foregroundStyle(RallyDesign.secondary)
        }
        .padding(10)
        .overlay(Capsule().stroke(RallyDesign.border, lineWidth: 1))
      }
      HStack(spacing: 10) {
        Image(systemName: "arrow.down")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(RallyDesign.red)
          .frame(width: 38)
        Text("tap +, then select rally")
          .font(.subheadline)
          .foregroundStyle(RallyDesign.secondary)
      }
      HStack(spacing: 12) {
        Image("RallyGuideIcon")
          .resizable().scaledToFit().frame(width: 38, height: 38)
          .clipShape(RoundedRectangle(cornerRadius: 9))
        Text("rally").font(.system(size: 16, weight: .semibold))
        Spacer()
        Image(systemName: "hand.tap").foregroundStyle(RallyDesign.red)
      }
      .padding(10)
      .background(.white, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(RallyDesign.red, lineWidth: 1))
    }
    .padding(14)
    .background(RallyDesign.muted, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "in your messages conversation, tap the plus button beside the message field, then select rally in the apps menu"
    )
  }

  private var login: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(("sign up or log in").lowercased()).font(.title3.weight(.semibold))
        Text(("use your email to create and manage your rallies.").lowercased())
        TextField(("email address").lowercased(), text: $email)
          .keyboardType(.emailAddress).textContentType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .textFieldStyle(RallyTextFieldStyle())
          .accessibilityLabel("Email address")
          .disabled(model.busy || model.signInEmail != nil)
        if model.isEnteringCode {
          if let notice = model.notice { Text((notice).lowercased()) }
          Text("enter your code")
          TextField(("email code").lowercased(), text: $code)
            .keyboardType(.numberPad).textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textFieldStyle(RallyTextFieldStyle())
            .accessibilityLabel("Email code")
            .disabled(model.busy)
            .onChange(of: code) { _, value in
              code = RallyAuthConfiguration.normalizedCode(value)
            }
          Button(model.busy ? "Signing in…" : "Sign in") {
            Task { await model.verifyCode(email: email, code: code) }
          }
          .buttonStyle(RallyActionButtonStyle())
          .disabled(
            model.busy || !RallyAuthConfiguration.isValidEmail(email)
              || !RallyAuthConfiguration.isValidCode(code))
          Button(("change email or request a new code").lowercased()) { model.resetSignIn() }
            .font(.footnote)
            .disabled(model.busy)
        } else {
          Button(model.busy ? "Sending…" : "Send sign-in email") {
            Task { await model.sendSignInEmail(email: email) }
          }
          .buttonStyle(RallyActionButtonStyle())
          .disabled(model.busy || !RallyAuthConfiguration.isValidEmail(email))
          Button(("i already have a code").lowercased()) { model.showCodeEntry() }
            .font(.footnote)
            .disabled(model.busy)
        }
        if let error = model.errorMessage { Text((error).lowercased()).foregroundStyle(.red) }
        RallyAppShareFooter()
      }.padding(24)
    }
  }

  private var dashboard: some View {
    List {
      if let error = model.errorMessage { Text((error).lowercased()).foregroundStyle(.red) }
      rallySection("needs you", key: "needs_you")
      rallySection("active", key: "active")
      rallySection("past", key: "past")
      Section {
        RallyAppShareFooter()
      }
      Section {
        VStack(alignment: .leading, spacing: 4) {
          if let email = model.account?.email {
            Text((email).lowercased()).font(.subheadline).foregroundStyle(.secondary)
          }
          HStack {
            Link(
              ("rally website").lowercased(),
              destination: URL(string: "https://rally-your-friends.com/my-rallies")!
            )
            .frame(minHeight: 44)
            Spacer()
            Button(("sign out").lowercased()) { Task { await model.signOut() } }
              .frame(minHeight: 44)
              .disabled(model.busy)
          }
          .font(.footnote)
          .buttonStyle(.borderless)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.white)
    .listStyle(.insetGrouped)
    .refreshable { await model.refresh() }
    .confirmationDialog(
      ("Delete this Rally?").lowercased(), isPresented: $showDeleteConfirmation,
      titleVisibility: .visible, presenting: rallyToDelete
    ) { rally in
      Button(("delete rally").lowercased(), role: .destructive) {
        Task { await deleteRally(rally) }
      }
      .disabled(model.busy)
      Button(("cancel").lowercased(), role: .cancel) { rallyToDelete = nil }
    } message: { rally in
      Text(
        ("This permanently deletes “\(rally.activity.isEmpty ? "Untitled draft" : rally.activity)” and all its responses. This can’t be undone.")
          .lowercased())
    }
    .alert(("Couldn’t delete Rally").lowercased(), isPresented: $showDeleteError) {
      Button(("ok").lowercased(), role: .cancel) {}
    } message: {
      Text((deleteError).lowercased())
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(("refresh").lowercased(), systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .labelStyle(.iconOnly)
        .disabled(model.busy)
      }
    }
  }

  private func rallySection(_ title: String, key: String) -> some View {
    Section(title.lowercased()) {
      let items = model.rallies.filter { $0.section == key }
      if items.isEmpty { Text(("no rallies here yet").lowercased()).foregroundStyle(.secondary) }
      ForEach(items) { rally in
        NavigationLink {
          RallyDetailView(model: model, rallyID: rally.id)
        } label: {
          RallyPlanCard {
            VStack(alignment: .leading, spacing: 6) {
              Text((rally.activity.isEmpty ? "untitled draft" : rally.activity).lowercased()).font(
                .headline)
              Text(
                ("\(RallyLabels.status(rally.status).lowercased()) · \(rally.responseCount) responses")
                  .lowercased()
              ).font(
                .subheadline)
              if let time = rally.time {
                Text((time.formatted(date: .abbreviated, time: .shortened)).lowercased())
              }
              if let location = rally.location { Text((location).lowercased()) }
              if rally.status == "draft" {
                Text(("finish on website").lowercased()).font(.body.weight(.semibold))
              } else if rally.nextAction != "none" {
                Text(RallyLabels.nextAction(rally.nextAction).lowercased()).font(
                  .subheadline.bold())
              }
            }
          }.padding(.vertical, 10)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(("delete").lowercased(), systemImage: "trash") {
            rallyToDelete = rally
            showDeleteConfirmation = true
          }
          .tint(.red)
          .disabled(model.busy)
        }
      }
    }
  }

  private func deleteRally(_ rally: OrganizerRally) async {
    guard !model.busy, model.rallies.contains(where: { $0.id == rally.id }) else { return }
    rallyToDelete = nil
    do {
      try await model.delete(id: rally.id)
    } catch {
      deleteError = model.message(for: error)
      showDeleteError = true
    }
  }
}

private struct RallyDetailView: View {
  @ObservedObject var model: RallyAccountModel
  let rallyID: String
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismiss) private var dismiss
  @State private var detail: OrganizerDetail?
  @State private var error: String?
  @State private var busy = false
  @State private var needsRefresh = false
  @State private var chosenTime = Date()
  @State private var hasChosenTime = false
  @State private var isChoosingTime = false
  @State private var pendingTime = Date()
  @State private var chosenLocation = ""
  @State private var pendingAction = ""
  @State private var showConfirmation = false
  @State private var calendarEvent: RallyCalendarEvent?
  @State private var showPlanShareSheet = false
  @State private var didAddToCalendar = false

  var body: some View {
    Group {
      if let detail {
        form(detail)
      } else if let error {
        VStack(spacing: 20) {
          Text((error).lowercased())
          Button(("try again").lowercased()) { Task { await reload() } }
        }.padding()
      } else {
        ProgressView("loading rally…")
      }
    }
    .navigationTitle(
      (detail?.rally.activity.isEmpty == false ? detail!.rally.activity : "Your Rally").lowercased()
    )
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button(("refresh").lowercased(), systemImage: "arrow.clockwise") {
          Task { await reload(preserveChoices: detail != nil && !needsRefresh) }
        }
        .labelStyle(.iconOnly)
        .disabled(busy || model.busy)
        if let detail, detail.rally.publishedAt != nil {
          ShareLink(item: detail.rally.publicUrl) {
            Label(("Share plan").lowercased(), systemImage: "square.and.arrow.up")
          }
          .labelStyle(.iconOnly)
          .disabled(busy || model.busy)
        }
      }
    }
    .task(id: rallyID) { await reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await reload(preserveChoices: true) } }
    }
    .sheet(isPresented: $isChoosingTime) {
      NavigationStack {
        DatePicker(("Final time").lowercased(), selection: $pendingTime)
          .datePickerStyle(.wheel)
          .labelsHidden()
          .padding()
          .navigationTitle(("final time").lowercased())
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(("cancel").lowercased()) { isChoosingTime = false }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button(("done").lowercased()) {
                chosenTime = pendingTime
                hasChosenTime = true
                isChoosingTime = false
              }
              .disabled(pendingTime <= Date())
            }
          }
      }
      .presentationDetents([.medium, .large])
    }
    .sheet(item: $calendarEvent) { event in
      RallyCalendarEditor(draft: event) { saved in
        didAddToCalendar = saved
        calendarEvent = nil
      }
    }
    .sheet(isPresented: $showPlanShareSheet) {
      if let message = detail?.rally.localPlanSummary {
        RallyPlanShareSheet(text: message.lowercased())
          .ignoresSafeArea()
      }
    }
    .confirmationDialog(
      ("\(pendingAction.capitalized) this Rally?").lowercased(), isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button(
        pendingAction == "confirm" ? "Confirm plan" : "\(pendingAction.capitalized) Rally",
        role: pendingAction == "delete" ? .destructive : nil
      ) {
        Task {
          if pendingAction == "delete" {
            await deleteRally()
          } else {
            await mutate(pendingAction)
          }
        }
      }
    } message: {
      Text((confirmationMessage).lowercased())
    }
  }

  private func form(_ detail: OrganizerDetail) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("your rally").font(.title3.weight(.semibold))
            RallyFinish()
          }
          Text(
            "\(RallyLabels.status(detail.rally.status).lowercased()) · \(detail.responses.count) responses"
          )
          .font(.subheadline).foregroundStyle(RallyDesign.secondary)
          if detail.rally.nextAction != "none" {
            Text("next: \(RallyLabels.nextAction(detail.rally.nextAction).lowercased())")
              .font(.subheadline).foregroundStyle(RallyDesign.secondary)
          }
          if let error { Text(error.lowercased()).font(.subheadline).foregroundStyle(.red) }
        }
        RallyPlanCard(drives: true) {
          VStack(alignment: .leading, spacing: 14) {
            planField("plan", value: detail.rally.activity, prominent: true)
            if let time = detail.rally.finalTime ?? detail.rally.startsAt {
              planField("when", value: time.formatted(date: .abbreviated, time: .shortened))
            } else if !detail.rally.candidates.isEmpty {
              VStack(alignment: .leading, spacing: 5) {
                Text("when (poll)").font(.subheadline).foregroundStyle(RallyDesign.secondary)
                ForEach(detail.rally.candidates) { candidate in
                  Text(
                    candidate.startsAt.formatted(date: .abbreviated, time: .shortened).lowercased()
                  )
                  .font(.subheadline)
                }
              }
            } else {
              planField("when", value: "to be decided")
            }
            planField("where", value: detail.rally.resolvedLocation ?? "to be decided")
          }
        }
        if detail.rally.status == "open" {
          choices(detail)
        } else {
          detailPanel("save this plan") {
            if let time = detail.rally.finalTime ?? detail.rally.startsAt {
              Text((time.formatted(date: .complete, time: .shortened)).lowercased())
            }
            LabeledContent(
              ("Location").lowercased(), value: detail.rally.resolvedLocation ?? "To be decided")
            if let event = RallyCalendarEvent(plan: detail.rally) {
              Button {
                didAddToCalendar = false
                calendarEvent = event
              } label: {
                Label(("Add to Calendar").lowercased(), systemImage: "calendar.badge.plus")
              }
              .buttonStyle(RallyActionButtonStyle())
              .disabled(busy || model.busy || needsRefresh)
              if didAddToCalendar {
                Label(("Added to Calendar").lowercased(), systemImage: "checkmark.circle")
                  .font(.footnote)
              }
            }
            if detail.rally.status == "draft" {
              Text(("this draft is private. open the website to finish it.").lowercased())
              Link(
                ("open my rallies").lowercased(),
                destination: URL(string: "https://rally-your-friends.com/my-rallies")!)
            }
          }
        }
        detailPanel("responses (\(detail.responses.count))") {
          if detail.responses.isEmpty {
            Text(("no responses yet").lowercased()).foregroundStyle(.secondary)
          }
          ForEach(detail.responses) { response in
            VStack(alignment: .leading, spacing: 6) {
              Text((response.name).lowercased()).font(.headline)
              Text((RallyLabels.response(response.consensus)).lowercased())
              if let note = response.note, !note.isEmpty { Text((note).lowercased()) }
              ForEach(response.suggestions, id: \.self) { Text(($0).lowercased()) }
              ForEach(response.timeSuggestions, id: \.self) { time in
                Text((time.formatted(date: .abbreviated, time: .shortened)).lowercased())
              }
            }
          }
        }
        if detail.rally.publishedAt != nil,
          ["confirmed", "completed"].contains(detail.rally.status),
          let message = detail.rally.localPlanSummary
        {
          detailPanel("plan summary") {
            Text((message).lowercased())
            Button {
              showPlanShareSheet = true
            } label: {
              Label("share plan", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(RallyActionButtonStyle())
            .accessibilityHint("share this summary through messages or another app")
            if detail.rally.resolvedLocation != nil,
              let maps = detail.rally.mapsUrl, maps.scheme == "https",
              maps.host == "www.google.com"
            {
              Link(("open in maps").lowercased(), destination: maps)
            }
          }
        }
        Button(role: .destructive) {
          confirm("delete")
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "trash")
            Text("delete rally")
            Spacer()
          }
          .font(.body)
          .foregroundStyle(RallyDesign.red)
          .padding(.horizontal, 16)
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(RallyDesign.muted, in: RoundedRectangle(cornerRadius: 10))
          .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(busy || model.busy || needsRefresh)
        RallyAppShareFooter()
      }
      .padding(20)
    }
    .background(Color.white)
    .font(.body)
  }

  private func choices(_ detail: OrganizerDetail) -> some View {
    detailPanel("choose the final plan") {
      ForEach(detail.rally.candidates) { candidate in
        Button {
          chosenTime = candidate.startsAt
          hasChosenTime = true
        } label: {
          HStack(spacing: 10) {
            Image(
              systemName: hasChosenTime && chosenTime == candidate.startsAt
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              hasChosenTime && chosenTime == candidate.startsAt
                ? RallyDesign.red : RallyDesign.secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.startsAt.formatted(date: .abbreviated, time: .omitted).lowercased())
                .font(.body.weight(.medium))
              Text(candidate.startsAt.formatted(date: .omitted, time: .shortened).lowercased())
                .font(.subheadline).foregroundStyle(RallyDesign.secondary)
            }
            Spacer()
            Text(
              "\(detail.responses.filter { $0.available.contains(candidate.id) }.count) available"
            )
            .font(.footnote)
            .foregroundStyle(RallyDesign.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RallyDesign.muted, in: Capsule())
          }
          .foregroundStyle(RallyDesign.ink)
          .padding(10)
          .background(.white, in: RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(
              hasChosenTime && chosenTime == candidate.startsAt
                ? RallyDesign.red : RallyDesign.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
          hasChosenTime && chosenTime == candidate.startsAt ? [.isSelected] : [])
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("final time").font(.body.weight(.semibold))
        Button {
          pendingTime = chosenTime
          isChoosingTime = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(RallyDesign.secondary)
            Text(
              hasChosenTime
                ? chosenTime.formatted(date: .abbreviated, time: .shortened).lowercased()
                : "choose date and time"
            )
            .font(.body)
            .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "pencil").foregroundStyle(RallyDesign.red)
          }
          .foregroundStyle(RallyDesign.ink)
          .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
          .padding(12)
          .background(.white, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(RallyDesign.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("change final time")
        .accessibilityValue(hasChosenTime ? chosenTime.formatted() : "not selected")
      }
      LocationAutocompleteField(title: "Final location", text: $chosenLocation)
      ForEach(
        Array(Set(detail.responses.flatMap(\.suggestions).compactMap { RallyLocation.value($0) }))
          .sorted(), id: \.self
      ) {
        suggestion in
        Button((suggestion).lowercased()) { chosenLocation = suggestion }
      }
      Button("save choices") { Task { await mutate("save") } }
        .buttonStyle(RallyActionButtonStyle())
        .disabled(chosenLocation.count > 200 || (hasChosenTime && chosenTime <= Date()))
      if hasChosenTime && chosenTime <= Date() {
        Text("choose a future time to confirm this plan")
          .font(.subheadline).foregroundStyle(RallyDesign.secondary)
      }
      Button(("confirm plan").lowercased()) { confirm("confirm") }
        .buttonStyle(RallyActionButtonStyle())
        .disabled(
          !hasChosenTime || chosenTime <= Date()
            || RallyLocation.value(chosenLocation) == nil
            || chosenLocation.count > 200)
    }.disabled(busy || model.busy || needsRefresh)
  }

  private func planField(_ title: String, value: String, prominent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline).foregroundStyle(RallyDesign.secondary)
      Text(value.lowercased())
        .font(prominent ? .title3.weight(.semibold) : .body)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func detailPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.body.weight(.semibold)).foregroundStyle(RallyDesign.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(RallyDesign.muted, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyDesign.border, lineWidth: 1))
  }

  private var confirmationMessage: String {
    switch pendingAction {
    case "delete":
      "This permanently deletes the Rally and all its responses. This can’t be undone."
    default:
      "This locks the selected time and place and closes replies."
    }
  }

  private func confirm(_ action: String) {
    pendingAction = action
    showConfirmation = true
  }

  private func apply(_ value: OrganizerDetail, preserveChoices: Bool = false) {
    detail = value
    if !preserveChoices {
      let time = value.rally.finalTime ?? value.rally.startsAt
      hasChosenTime = time != nil
      chosenTime = time ?? Date().addingTimeInterval(86400)
      chosenLocation = value.rally.resolvedLocation ?? ""
    }
  }

  private func reload(preserveChoices: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      apply(try await model.detail(id: rallyID), preserveChoices: preserveChoices)
      error = nil
      needsRefresh = false
    } catch AccountAPIError.notFound {
      dismiss()
    } catch { self.error = model.message(for: error) }
  }

  private func mutate(_ action: String) async {
    guard !busy, !needsRefresh else { return }
    busy = true
    defer { busy = false }
    do {
      apply(
        try await model.update(
          id: rallyID, action: action,
          time: hasChosenTime ? chosenTime : nil, location: chosenLocation))
      error = nil
    } catch {
      self.error = model.message(for: error)
      needsRefresh = true
    }
  }

  private func deleteRally() async {
    guard !busy, !needsRefresh else { return }
    busy = true
    defer { busy = false }
    do {
      try await model.delete(id: rallyID)
      dismiss()
    } catch {
      self.error = model.message(for: error)
      needsRefresh = true
    }
  }
}

private struct RallyPlanShareSheet: UIViewControllerRepresentable {
  let text: String

  func makeUIViewController(context: Context) -> UIActivityViewController {
    // NSString supplies plain text to native activities, including Messages.
    UIActivityViewController(activityItems: [text as NSString], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
