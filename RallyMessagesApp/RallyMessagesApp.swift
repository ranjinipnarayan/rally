import SwiftUI

@main
struct RallyMessagesApp: App {
  @StateObject private var model = RallyAccountModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await model.refresh() } }
        }
    }
  }
}
