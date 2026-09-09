import SwiftUI

struct ContentView: View {
  @ObservedObject var model: RallyAccountModel
  @State private var email = ""
  @State private var code = ""

  var body: some View {
    NavigationStack {
      Group {
        if model.loading {
          ProgressView("Loading Rally…")
        } else if model.account == nil {
          login
        } else {
          dashboard
        }
      }
      .navigationTitle("Rally")
    }
    .id(model.account?.id)
    .tint(.black)
    .preferredColorScheme(.light)
    .onChange(of: model.isEnteringCode) { _, _ in code = "" }
    .onChange(of: model.signInEmail) { _, sentEmail in
      if let sentEmail { email = sentEmail }
    }
    .onChange(of: model.account?.id) { _, _ in
      email = ""
      code = ""
    }
  }

  private var login: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 48))
        Text("Make a plan. Bring your friends.").font(.largeTitle.bold())
        Text("Sign in to save drafts, share plans in Messages, and manage your Rallies.")
        TextField("Email address", text: $email)
          .keyboardType(.emailAddress).textContentType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Email address")
          .disabled(model.busy || model.signInEmail != nil)
        if model.isEnteringCode {
          if let notice = model.notice { Text(notice) }
          Text(
            "Enter the code from your sign-in email here. You can read the email on another device, or open its link on this device."
          )
          TextField("Email code", text: $code)
            .keyboardType(.numberPad).textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
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
          Button("Change email or request a new code") { model.resetSignIn() }
            .font(.footnote)
            .disabled(model.busy)
        } else {
          Button(model.busy ? "Sending…" : "Send sign-in email") {
            Task { await model.sendSignInEmail(email: email) }
          }
          .buttonStyle(RallyActionButtonStyle())
          .disabled(model.busy || !RallyAuthConfiguration.isValidEmail(email))
          Button("I already have a code") { model.showCodeEntry() }
            .font(.footnote)
            .disabled(model.busy)
        }
        if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        Divider()
        Text("To create a plan: open a Messages conversation, tap +, and choose Rally.")
      }.padding(24)
    }
  }

  private var dashboard: some View {
    List {
      if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
      rallySection("Needs You", key: "needs_you")
      rallySection("Active", key: "active")
      rallySection("Past", key: "past")
      Section {
        VStack(alignment: .leading, spacing: 4) {
          if let email = model.account?.email {
            Text(email).font(.caption).foregroundStyle(.secondary)
          }
          HStack {
            Link(
              "Rally website",
              destination: URL(string: "https://rally-your-friends.com/my-rallies")!
            )
            .frame(minHeight: 44)
            Spacer()
            Button("Sign out") { Task { await model.signOut() } }
              .frame(minHeight: 44)
              .disabled(model.busy)
          }
          .font(.footnote)
          .buttonStyle(.borderless)
        }
      }
    }
    .refreshable { await model.refresh() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
          .labelStyle(.iconOnly)
          .disabled(model.busy)
      }
    }
  }

  private func rallySection(_ title: String, key: String) -> some View {
    Section(title) {
      let items = model.rallies.filter { $0.section == key }
      if items.isEmpty { Text("No Rallies here yet").foregroundStyle(.secondary) }
      ForEach(items) { rally in
        NavigationLink {
          RallyDetailView(model: model, rallyID: rally.id)
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            Text(rally.activity.isEmpty ? "Untitled draft" : rally.activity).font(.headline)
            Text("\(RallyLabels.status(rally.status)) · \(rally.responseCount) responses").font(
              .subheadline)
            if let time = rally.time { Text(time.formatted(date: .abbreviated, time: .shortened)) }
            if let location = rally.location { Text(location) }
            if rally.status == "draft" {
              Text("Finish draft").font(.subheadline.bold())
            } else if rally.nextAction != "none" {
              Text(RallyLabels.nextAction(rally.nextAction)).font(.subheadline.bold())
            }
          }.padding(.vertical, 4)
        }
      }
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

  var body: some View {
    Group {
      if let detail {
        form(detail)
      } else if let error {
        VStack(spacing: 20) {
          Text(error)
          Button("Try again") { Task { await reload() } }
        }.padding()
      } else {
        ProgressView("Loading Rally…")
      }
    }
    .navigationTitle(
      detail?.rally.activity.isEmpty == false ? detail!.rally.activity : "Your Rally"
    )
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await reload(preserveChoices: detail != nil && !needsRefresh) }
        }
        .labelStyle(.iconOnly)
        .disabled(busy || model.busy)
      }
    }
    .task(id: rallyID) { await reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await reload(preserveChoices: true) } }
    }
    .sheet(isPresented: $isChoosingTime) {
      NavigationStack {
        DatePicker("Final time", selection: $pendingTime)
          .datePickerStyle(.wheel)
          .labelsHidden()
          .padding()
          .navigationTitle("Final time")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { isChoosingTime = false }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
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
    .confirmationDialog(
      "\(pendingAction.capitalized) this Rally?", isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button(
        pendingAction == "confirm" ? "Confirm plan" : "\(pendingAction.capitalized) Rally",
        role: ["cancel", "delete"].contains(pendingAction) ? .destructive : nil
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
      Text(confirmationMessage)
    }
  }

  private func form(_ detail: OrganizerDetail) -> some View {
    Form {
      Section {
        Text(RallyLabels.status(detail.rally.status)).font(.headline)
        Text("\(detail.responses.count) responses")
        if detail.rally.nextAction != "none" {
          Text(RallyLabels.nextAction(detail.rally.nextAction))
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      if detail.rally.status == "open" {
        choices(detail)
      } else {
        Section("Plan") {
          if let time = detail.rally.finalTime ?? detail.rally.startsAt {
            Text(time.formatted(date: .complete, time: .shortened))
          }
          LabeledContent("Location", value: detail.rally.resolvedLocation ?? "To be decided")
          if detail.rally.status == "draft" {
            Text(
              "This draft is private. Continue editing it in Messages, or finish it on the website."
            )
            Link(
              "Open My Rallies",
              destination: URL(string: "https://rally-your-friends.com/my-rallies")!)
          }
        }
      }
      Section("Responses") {
        if detail.responses.isEmpty { Text("No responses yet").foregroundStyle(.secondary) }
        ForEach(detail.responses) { response in
          VStack(alignment: .leading, spacing: 6) {
            Text(response.name).font(.headline)
            Text(RallyLabels.response(response.consensus))
            if let note = response.note, !note.isEmpty { Text(note) }
            ForEach(response.suggestions, id: \.self) { Text($0) }
            ForEach(response.timeSuggestions, id: \.self) { time in
              Text(time.formatted(date: .abbreviated, time: .shortened))
            }
          }
        }
      }
      if detail.rally.publishedAt != nil {
        Section("Share") {
          if ["confirmed", "completed"].contains(detail.rally.status),
            let message = detail.rally.finalMessage
          {
            Text(message)
            ShareLink(item: message) { Label("Share plan", systemImage: "square.and.arrow.up") }
            if detail.rally.resolvedLocation != nil,
              let maps = detail.rally.mapsUrl, maps.scheme == "https",
              maps.host == "www.google.com"
            {
              Link("Open in Maps", destination: maps)
            }
          }
          Link("Open Rally in website", destination: detail.rally.publicUrl)
        }
      }
      Section {
        if ["draft", "open", "confirmed"].contains(detail.rally.status) {
          Button("Cancel Rally", role: .destructive) { confirm("cancel") }
            .buttonStyle(RallyActionButtonStyle())
        }
        Button("Delete Rally", role: .destructive) {
          confirm("delete")
        }
        .buttonStyle(RallyActionButtonStyle())
      }.disabled(busy || model.busy || needsRefresh)
    }
  }

  private func choices(_ detail: OrganizerDetail) -> some View {
    Section("Choose the final plan") {
      ForEach(detail.rally.candidates) { candidate in
        Button {
          chosenTime = candidate.startsAt
          hasChosenTime = true
        } label: {
          VStack(alignment: .leading) {
            Text(candidate.startsAt.formatted(date: .abbreviated, time: .shortened))
            Text(
              "\(detail.responses.filter { $0.available.contains(candidate.id) }.count) available"
            ).font(.caption)
          }
        }
      }
      LabeledContent("Final time") {
        Button {
          pendingTime = chosenTime
          isChoosingTime = true
        } label: {
          Text(
            hasChosenTime
              ? chosenTime.formatted(date: .abbreviated, time: .shortened)
              : "Select date and time")
        }
        .accessibilityLabel("Final time")
        .accessibilityValue(
          hasChosenTime
            ? chosenTime.formatted(date: .abbreviated, time: .shortened) : "Not selected")
      }
      LocationAutocompleteField(title: "Final location", text: $chosenLocation)
      ForEach(
        Array(Set(detail.responses.flatMap(\.suggestions).compactMap { RallyLocation.value($0) }))
          .sorted(), id: \.self
      ) {
        suggestion in
        Button(suggestion) { chosenLocation = suggestion }
      }
      Button("Save choices") { Task { await mutate("save") } }
        .buttonStyle(RallyActionButtonStyle())
        .disabled(chosenLocation.count > 200 || (hasChosenTime && chosenTime <= Date()))
      Button("Confirm plan") { confirm("confirm") }
        .buttonStyle(RallyActionButtonStyle())
        .disabled(
          !hasChosenTime || chosenTime <= Date()
            || RallyLocation.value(chosenLocation) == nil
            || chosenLocation.count > 200)
    }.disabled(busy || model.busy || needsRefresh)
  }

  private var confirmationMessage: String {
    switch pendingAction {
    case "delete":
      "This permanently deletes the Rally and all its responses. This can’t be undone."
    case "cancel":
      "This closes the Rally to new responses. You can still review the existing responses."
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

private struct RallyActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 48)
      .background(
        Color.black.opacity(isEnabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 10)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}
