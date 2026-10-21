import SwiftUI

/// Curve instructions and completion actions sit above the field, clear of the drawing bar.
struct CurveControls: View {
    var pointCount: Int
    var finish: () -> Void
    var cancel: () -> Void

    var instruction: String {
        switch pointCount {
        case 0: return "Click to place the start of the curve."
        case 1: return "Click to place the end of the curve."
        default: return "Click between points to shape the curve. Drag points to adjust, then choose Finish Curve."
        }
    }

    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Text(instruction)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Space.m) {
                Button("Cancel Curve", action: cancel)
                    .disabled(pointCount == 0)
                    .help("Discard this curve (Escape)")
                Button("Finish Curve", action: finish)
                    .fwPrimaryButton()
                    .disabled(pointCount < 2)
                    .help("Keep this curve and stop adding points (Return)")
                    .accessibilityIdentifier("curve.finish")
            }
            Text("Return to finish · Delete to undo a point · Escape to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity)
        .floatingGlass()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Curve controls")
    }
}
