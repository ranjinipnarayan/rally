import SwiftUI

struct RallyAppShareFooter: View {
  private static let invitationURL = URL(string: "https://testflight.apple.com/join/zqqPHTFS")!

  var body: some View {
    ShareLink(item: Self.invitationURL) {
      Text("share the rally app")
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
  }
}
