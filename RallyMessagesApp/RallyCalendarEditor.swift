import EventKit
import EventKitUI
import SwiftUI

struct RallyCalendarEditor: UIViewControllerRepresentable {
  let draft: RallyCalendarEvent
  let onComplete: (Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onComplete: onComplete)
  }

  func makeUIViewController(context: Context) -> EKEventEditViewController {
    let store = context.coordinator.store
    let event = EKEvent(eventStore: store)
    event.title = draft.title
    event.timeZone = .current
    event.startDate = draft.startDate
    event.endDate = draft.endDate
    event.isAllDay = false
    event.location = draft.location
    event.url = draft.url
    event.notes = draft.notes

    // On iOS 17+, the system editor handles calendar selection and saving
    // without requiring Rally to request access to the person's calendars.
    let controller = EKEventEditViewController()
    controller.eventStore = store
    controller.event = event
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

  final class Coordinator: NSObject, EKEventEditViewDelegate {
    let store = EKEventStore()
    private let onComplete: (Bool) -> Void

    init(onComplete: @escaping (Bool) -> Void) {
      self.onComplete = onComplete
    }

    func eventEditViewController(
      _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
    ) {
      onComplete(action == .saved)
    }
  }
}
