import SwiftUI

struct ContentView: View {
  @ObservedObject var model: RallyAccountModel
  @State private var email = ""

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
        Button(model.busy ? "Sending…" : "Email me a sign-in link") {
          Task { await model.sendLink(email: email) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.busy || !email.contains("@"))
        if let notice = model.notice { Text(notice) }
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
        Link(
          "My Rallies on the web",
          destination: URL(string: "https://rally-your-friends.com/my-rallies")!)
        if let email = model.account?.email { Text(email).foregroundStyle(.secondary) }
        Button("Sign out") { Task { await model.signOut() } }.disabled(model.busy)
      }
    }
    .refreshable { await model.refresh() }
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
        .disabled(model.busy)
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
  @State private var detail: OrganizerDetail?
  @State private var error: String?
  @State private var busy = false
  @State private var needsRefresh = false
  @State private var chosenTime = Date()
  @State private var hasChosenTime = false
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
    .task(id: rallyID) { await reload() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await reload(preserveChoices: true) } }
    }
    .confirmationDialog(
      "\(pendingAction.capitalized) this Rally?", isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button(pendingAction.capitalized, role: pendingAction == "cancel" ? .destructive : nil) {
        Task { await mutate(pendingAction) }
      }
    } message: {
      Text(
        pendingAction == "confirm"
          ? "This locks the selected time and place and closes replies."
          : "This updates the Rally for your account.")
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
        Button("Refresh") { Task { await reload() } }.disabled(busy)
      }
      if detail.rally.status == "open" {
        choices(detail)
      } else {
        Section("Plan") {
          if let time = detail.rally.finalTime ?? detail.rally.startsAt {
            Text(time.formatted(date: .complete, time: .shortened))
          }
          if let place = detail.rally.finalLocation ?? detail.rally.location { Text(place) }
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
            if let maps = detail.rally.mapsUrl, maps.scheme == "https",
              maps.host == "www.google.com"
            {
              Link("Open in Maps", destination: maps)
            }
          }
          Link("Open public Rally", destination: detail.rally.publicUrl)
        }
      }
      Section {
        if ["draft", "open", "confirmed"].contains(detail.rally.status) {
          Button("Cancel Rally", role: .destructive) { confirm("cancel") }
        }
        Button(detail.rally.archivedAt == nil ? "Archive" : "Unarchive") {
          confirm(detail.rally.archivedAt == nil ? "archive" : "unarchive")
        }
      }.disabled(busy || needsRefresh)
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
      Toggle("Choose a time", isOn: $hasChosenTime)
      if hasChosenTime {
        DatePicker("Final time", selection: $chosenTime).foregroundStyle(Color.primary)
      }
      TextField("Final location", text: $chosenLocation)
      ForEach(Array(Set(detail.responses.flatMap(\.suggestions))).sorted(), id: \.self) {
        suggestion in
        Button(suggestion) { chosenLocation = suggestion }
      }
      Button("Save choices") { Task { await mutate("save") } }
        .disabled(chosenLocation.count > 200 || (hasChosenTime && chosenTime <= Date()))
      Button("Confirm plan") { confirm("confirm") }
        .disabled(
          !hasChosenTime || chosenTime <= Date()
            || chosenLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || chosenLocation.count > 200)
    }.disabled(busy || needsRefresh)
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
      chosenLocation = value.rally.finalLocation ?? value.rally.location ?? ""
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
}
