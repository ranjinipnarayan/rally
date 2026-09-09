import Messages
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
  private var hostingController: UIHostingController<MessageComposerView>?
  private let submission = RallySubmissionModel()
  private var activationID = UUID()

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .light
    view.backgroundColor = .white
    renderComposer()
  }

  override func willBecomeActive(with conversation: MSConversation) {
    super.willBecomeActive(with: conversation)
    activationID = UUID()
    submission.refreshSession()
    renderComposer()
  }

  override func willResignActive(with conversation: MSConversation) {
    super.willResignActive(with: conversation)
    activationID = UUID()
  }

  override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
    super.didTransition(to: presentationStyle)
    renderComposer()
  }

  private func renderComposer() {
    let rootView = MessageComposerView(
      isExpanded: presentationStyle == .expanded,
      submission: submission,
      onExpand: { [weak self] in
        self?.requestPresentationStyle(.expanded)
      },
      onSignIn: { [weak self] in
        guard let context = self?.extensionContext,
          let url = URL(string: "com.example.RallyMessages://signin")
        else { return false }
        return await withCheckedContinuation { continuation in
          context.open(url) { opened in continuation.resume(returning: opened) }
        }
      },
      onSendPlan: { [weak self] plan in
        self?.insertPlan(plan)
      }
    )

    if let hostingController {
      hostingController.rootView = rootView
      return
    }

    let controller = UIHostingController(rootView: rootView)
    controller.overrideUserInterfaceStyle = .light
    controller.view.backgroundColor = .white
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    hostingController = controller
  }

  private func insertPlan(_ plan: PlanPayload) {
    guard let conversation = activeConversation else { return }
    let activation = activationID
    Task { @MainActor [weak self] in
      guard let self else { return }
      await submission.submit(plan) { [weak self] rally in
        guard let self, self.activationID == activation,
          self.activeConversation === conversation
        else {
          throw RallyIntegrationError.conversationUnavailable
        }
        // Plain text HTTPS links open the public website for every recipient.
        // No MSMessage payload, creator token, or session credential is shared.
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          conversation.insertText("\(rally.title)\n\(rally.publicURL.absoluteString)") { error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }
        if self.activationID == activation {
          self.requestPresentationStyle(.compact)
        }
      }
    }
  }
}
