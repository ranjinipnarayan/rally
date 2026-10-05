import SwiftUI

/// Native counterparts of rally-your-friends/src/styles.css.
enum RallyDesign {
  static let ink = Color(red: 0.059, green: 0.090, blue: 0.165)
  static let red = Color(red: 0.82, green: 0.12, blue: 0.16)
  static let muted = Color(red: 0.945, green: 0.961, blue: 0.976)
  static let border = Color(red: 0.886, green: 0.910, blue: 0.941)
  static let secondary = Color(red: 0.392, green: 0.455, blue: 0.545)
}

struct RallyActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(RallyDesign.ink, in: RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
  }
}

/// The website's car artwork, drawn in its original 80 × 40 coordinate space.
struct RallyCar: View {
  var body: some View {
    Canvas { context, size in
      context.scaleBy(x: size.width / 80, y: size.height / 40)
      func polygon(_ points: [CGPoint], color: Color) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        context.fill(path, with: .color(color))
      }
      polygon(
        [
          CGPoint(x: 5, y: 29), CGPoint(x: 5, y: 19), CGPoint(x: 13, y: 9),
          CGPoint(x: 10, y: 6), CGPoint(x: 29, y: 2), CGPoint(x: 46, y: 2),
          CGPoint(x: 59, y: 9), CGPoint(x: 68, y: 15), CGPoint(x: 77, y: 19),
          CGPoint(x: 79, y: 29),
        ], color: Color(white: 0.065))
      polygon(
        [
          CGPoint(x: 20, y: 10), CGPoint(x: 27, y: 7), CGPoint(x: 27, y: 15),
          CGPoint(x: 16, y: 13),
        ], color: .white)
      polygon(
        [
          CGPoint(x: 31, y: 7), CGPoint(x: 42, y: 7), CGPoint(x: 43, y: 16),
          CGPoint(x: 31, y: 15),
        ], color: .white)
      polygon(
        [
          CGPoint(x: 47, y: 7), CGPoint(x: 57, y: 12), CGPoint(x: 65, y: 17),
          CGPoint(x: 48, y: 16),
        ], color: .white)
      polygon(
        [CGPoint(x: 6, y: 18), CGPoint(x: 9, y: 14), CGPoint(x: 11, y: 19)],
        color: RallyDesign.red)
      for x in [12.0, 56.0] {
        context.fill(
          Path(ellipseIn: CGRect(x: x, y: 21, width: 16, height: 16)),
          with: .color(Color(white: 0.065)))
      }
    }
    .accessibilityHidden(true)
  }
}

struct RallyJourney: View {
  let step: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let distance = max(0, geometry.size.width - 28)
      Path { path in
        path.move(to: CGPoint(x: 14, y: 18))
        path.addLine(to: CGPoint(x: geometry.size.width - 14, y: 18))
      }.stroke(RallyDesign.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      ForEach(0..<4) { index in
        Circle().fill(RallyDesign.red).frame(width: 5, height: 5)
          .position(x: 14 + distance * CGFloat(index) / 3, y: 18)
      }
      RallyCar().frame(width: 28, height: 14)
        .position(x: 14 + distance * CGFloat(step) / 3, y: 13)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: step)
    }
    .frame(height: 32)
    .accessibilityHidden(true)
  }
}

/// A single 3.6-second perimeter lap on arrival, repeated on pointer hover.
struct RallyPlanCard<Content: View>: View {
  var drives = false
  @ViewBuilder let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var started = Date()
  @State private var isDriving = true

  var body: some View {
    content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(.white, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(RallyDesign.red, lineWidth: 1))
      .shadow(color: .black.opacity(0.03), radius: 7, y: 3)
      .overlay {
        if drives {
          TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isDriving)) {
            timeline in
            GeometryReader { geometry in
              let t =
                reduceMotion ? 0 : min(1, max(0, timeline.date.timeIntervalSince(started) / 3.6))
              let point = position(t, size: geometry.size)
              RallyCar().frame(width: 28, height: 14)
                .rotationEffect(.degrees(point.2))
                .position(x: point.0, y: point.1)
            }
            .padding(-16)
          }
          .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .onAppear {
        started = Date()
        isDriving = drives && !reduceMotion
      }
      .onHover {
        if $0 {
          started = Date()
          isDriving = drives && !reduceMotion
        }
      }
      .task(id: started) {
        guard drives, !reduceMotion else { return }
        try? await Task.sleep(for: .seconds(3.6))
        guard !Task.isCancelled else { return }
        isDriving = false
      }
  }

  private func position(_ t: Double, size: CGSize) -> (CGFloat, CGFloat, Double) {
    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 16, dy: 16)
    let path = Path(roundedRect: rect, cornerRadius: 10)
    let progress = max(0.0001, min(0.9999, t))
    let point =
      path.trimmedPath(from: 0, to: progress).currentPoint
      ?? CGPoint(x: rect.minX + 10, y: rect.minY)
    let before =
      path.trimmedPath(from: 0, to: max(0.00001, progress - 0.00001)).currentPoint ?? point
    let angle = atan2(point.y - before.y, point.x - before.x) * 180 / .pi
    return (point.x, point.y, angle)
  }

}

struct RallyFinish: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var started = Date()
  @State private var waving = false

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1 / 24,
        paused: reduceMotion || !waving || scenePhase != .active)
    ) { timeline in
      Canvas { context, size in
        context.scaleBy(x: size.width / 24, y: size.height / 24)
        let elapsed = max(0, timeline.date.timeIntervalSince(started))
        let envelope = reduceMotion || !waving ? 0 : sin(min(elapsed / 1.8, 1) * .pi)
        var pole = Path()
        pole.move(to: CGPoint(x: 5, y: 3))
        pole.addLine(to: CGPoint(x: 5, y: 21))
        context.stroke(pole, with: .color(RallyDesign.ink), lineWidth: 1.8)
        for row in 0..<3 {
          for column in 0..<4 {
            var cell = Path()
            for (index, corner) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].enumerated() {
              let x = Double(column) + corner.0
              let ripple = sin(x / 4 * 7 - elapsed * 10) * x / 4 * envelope
              let point = CGPoint(
                x: 6 + x * 3.5, y: 4 + (Double(row) + corner.1) * 3.3 + ripple * 1.5)
              if index == 0 { cell.move(to: point) } else { cell.addLine(to: point) }
            }
            cell.closeSubpath()
            context.fill(cell, with: .color((row + column) % 2 == 0 ? RallyDesign.ink : .white))
            context.stroke(cell, with: .color(RallyDesign.ink), lineWidth: 0.3)
          }
        }
      }
    }
    .frame(width: 24, height: 24).accessibilityHidden(true)
    .task(id: reduceMotion || scenePhase != .active) {
      waving = false
      guard !reduceMotion, scenePhase == .active else { return }
      do {
        while !Task.isCancelled {
          started = Date()
          waving = true
          try await Task.sleep(for: .seconds(1.8))
          waving = false
          try await Task.sleep(for: .seconds(1.2))
        }
      } catch {
        waving = false
      }
    }
  }
}

struct RallyTextFieldStyle: TextFieldStyle {
  @FocusState private var focused: Bool
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.font(.system(size: 14)).padding(12)
      .foregroundStyle(RallyDesign.ink)
      .background(.white, in: RoundedRectangle(cornerRadius: 6))
      .focused($focused)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(focused ? RallyDesign.red : RallyDesign.border, lineWidth: focused ? 2 : 1))
  }
}
