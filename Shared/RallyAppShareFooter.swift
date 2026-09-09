import SwiftUI

struct RallyAppShareFooter: View {
  private static let invitationURL = URL(string: "https://testflight.apple.com/join/zqqPHTFS")!

  var body: some View {
    ShareLink(item: Self.invitationURL) {
      Text("Share the Rally app")
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.black)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.white)
  }
}
