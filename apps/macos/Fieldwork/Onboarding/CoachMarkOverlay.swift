import SwiftUI
import FieldworkTour

/// Anchored coach marks. One bubble at a time, positioned from the target's
/// live geometry (no fixed coordinates). If the target is not on screen the
/// bubble collapses into a card with the fallback instruction. Steps advance
/// only when the model reports a successful action.
struct CoachMarkOverlay: View {
    @ObservedObject var model: EditorModel
    var anchors: [String: Anchor<CGRect>]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let step = model.tour.currentStep {
                let index = model.tour.steps.firstIndex { $0.id == step.id } ?? 0
                if let anchor = anchors[step.targetID] {
                    let rect = proxy[anchor]
                    let below = rect.maxY + 170 < proxy.size.height
                    let x = min(max(rect.midX, 170), proxy.size.width - 170)
                    VStack(spacing: 0) {
                        if below { Arrow().fill(Color.fwSurface).frame(width: 18, height: 9).offset(x: rect.midX - x) }
                        bubble(step, index: index, fallback: false)
                        if !below { Arrow().fill(Color.fwSurface).frame(width: 18, height: 9).rotationEffect(.degrees(180)).offset(x: rect.midX - x) }
                    }
                    .frame(width: 320)
                    .position(x: x, y: below ? rect.maxY + 80 : rect.minY - 80)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step.id)
                } else {
                    bubble(step, index: index, fallback: true)
                        .frame(width: 320)
                        .position(x: proxy.size.width - 180, y: proxy.size.height - 140)
                }
            }
        }
    }

    private func bubble(_ step: TourStep, index: Int, fallback: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack {
                Text(step.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(index + 1) of \(model.tour.steps.count)").font(.caption).foregroundStyle(Color.fwSecondary)
            }
            Text(fallback ? "\(step.body) \(step.fallback)" : step.body)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { model.tourBack() }.disabled(!model.tour.canGoBack)
                Spacer()
                Button("Skip") { model.tourSkip() }
                Button("Close") { model.tourDismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(Tokens.Space.m)
        .background(Color.fwSurface, in: RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous).strokeBorder(Color.fwAccent.opacity(0.6)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting started, step \(index + 1) of \(model.tour.steps.count): \(step.title)")
        .accessibilityAddTraits(.isModal)
    }
}

struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
