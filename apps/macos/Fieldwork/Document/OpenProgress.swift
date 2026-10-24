import AppKit
import SwiftUI

/// The steps of opening a show, as listed in the progress window.
enum OpenStep: Int, CaseIterable {
    case reading, verifying, loadingDrill, recovery, preparing

    var title: String {
        switch self {
        case .reading: "Reading file"
        case .verifying: "Checking for damage"
        case .loadingDrill: "Loading drill"
        case .recovery: "Saving a recovery copy"
        case .preparing: "Opening the editor"
        }
    }

    /// Share of the whole bar: roughly how long each step takes on a large show.
    var weight: Double {
        switch self {
        case .reading: 0.15
        case .verifying: 0.2
        case .loadingDrill: 0.35
        case .recovery: 0.15
        case .preparing: 0.15
        }
    }
}

@MainActor
final class OpenProgressModel: ObservableObject {
    let name: String
    @Published var step: OpenStep = .reading
    @Published var stepFraction: Double = 0
    @Published var detail = ""

    init(name: String) { self.name = name }

    var overall: Double {
        let done = OpenStep.allCases.filter { $0.rawValue < step.rawValue }.reduce(0) { $0 + $1.weight }
        return min(1, done + step.weight * min(max(stepFraction, 0), 1))
    }
}

struct OpenProgressView: View {
    @ObservedObject var model: OpenProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Opening “\(model.name)”")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: model.overall)
            HStack {
                Text(model.detail.isEmpty ? "\(model.step.title)…" : "\(model.step.title) · \(model.detail)")
                    .foregroundStyle(Color.fwSecondary)
                Spacer()
                Text("\(Int((model.overall * 100).rounded(.down)))%").monospacedDigit()
            }
            .font(.system(size: 12))
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(OpenStep.allCases, id: \.self) { step in
                    HStack(spacing: Tokens.Space.s) {
                        Group {
                            if step.rawValue < model.step.rawValue {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fwAccent)
                            } else if step == model.step {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(Color.fwSecondary.opacity(0.6))
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(step.title)
                            .foregroundStyle(step.rawValue > model.step.rawValue ? Color.fwSecondary : Color.primary)
                    }
                    .font(.system(size: 13))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(step.rawValue < model.step.rawValue ? "Done" : step == model.step ? "In progress" : "Waiting")
                }
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 380)
    }
}

/// Reports opening progress from the background reader to a small window on the
/// main thread. Updates are coalesced so a fast loop never floods the main queue,
/// and the window only appears if opening takes more than a moment, so small
/// shows open without a flash.
final class OpenProgress: @unchecked Sendable {
    private static let showDelay: TimeInterval = 0.3
    /// Reading a show this slowly means building its editor will also block the
    /// main thread for a while, so the window comes up before that step even
    /// when the delay above has not passed yet.
    private static let slowReadThreshold: TimeInterval = 0.1

    private let name: String
    private let started = CACurrentMediaTime()
    private let lock = NSLock()
    private var pending: (step: OpenStep, fraction: Double, detail: String)?
    private var deliveryScheduled = false
    // Main thread only.
    private var model: OpenProgressModel?
    private var panel: NSPanel?
    private var finished = false

    /// The model is made on first use, not on a later main-queue turn: when
    /// NSDocument reads on the main thread, the editor step comes before that turn.
    init(name: String) {
        self.name = name
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay) {
            MainActor.assumeIsolated { self.showWindow() }
        }
    }

    /// Safe from any thread.
    func report(_ step: OpenStep, _ fraction: Double, detail: String = "") {
        lock.lock()
        pending = (step, fraction, detail)
        let schedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.deliver() }
        }
    }

    /// Enters the last step, which runs on the main thread and can't update the
    /// window while it works, so a large show gets its window drawn first.
    @MainActor
    func beginPreparingEditor(isLarge: Bool) {
        report(.preparing, 0)
        guard isLarge || CACurrentMediaTime() - started >= Self.slowReadThreshold else { return }
        deliver()
        showWindow()
        panel?.displayIfNeeded()
    }

    /// Closes the window, or keeps it from ever appearing. Safe from any thread.
    func finish() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.finished = true
                self.panel?.close()
                self.panel = nil
            }
        }
    }

    @MainActor
    private func makeModel() -> OpenProgressModel {
        if let model { return model }
        let model = OpenProgressModel(name: name)
        self.model = model
        return model
    }

    @MainActor
    private func deliver() {
        lock.lock()
        let update = pending
        pending = nil
        deliveryScheduled = false
        lock.unlock()
        guard let update else { return }
        let model = makeModel()
        model.step = update.step
        model.stepFraction = update.fraction
        model.detail = update.detail
    }

    @MainActor
    private func showWindow() {
        guard !finished, panel == nil else { return }
        let model = makeModel()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Opening Show"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingController(rootView: OpenProgressView(model: model))
        // Sized once here: if SwiftUI resized the panel later it would drift off center.
        // Without sizing options the hosting view's fittingSize is zero, so ask SwiftUI directly.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(hosting.sizeThatFits(in: CGSize(width: 380, height: 10_000)))
        // The middle of the screen you're working on; `center()` sits higher than the middle on purpose.
        if let area = (NSScreen.main ?? panel.screen)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (area.midX - panel.frame.width / 2).rounded(), y: (area.midY - panel.frame.height / 2).rounded()))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}
