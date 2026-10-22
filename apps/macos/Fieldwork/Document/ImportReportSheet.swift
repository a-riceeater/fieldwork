import AppKit
import SwiftUI

/// Shown once over a newly imported drill: what was saved, what is worth
/// checking and what changed, in plain language. The converter's own wording
/// stays available under Technical Details.
struct ImportReportSheet: View {
    let report: ImportReport
    /// Pins count 0 of the open show to an offset, once the count track uses it.
    var alignShow: ((Double) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showsTechnical = false
    @State private var realign = RealignState.idle

    private enum RealignState: Equatable {
        case idle, running, done
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.l)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.l) {
                    if !report.savedFiles.isEmpty { savedFiles }
                    if report.notes.isEmpty {
                        Label("Everything converted cleanly. There's nothing to check.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.fwAccent)
                    }
                    noteGroup("Worth checking", notes: report.needsAttention)
                    noteGroup("Good to know", notes: report.forYourInformation)
                    if !report.notes.isEmpty { technical }
                }
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.l)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .fwPrimaryButton()
            }
            .padding(Tokens.Space.l)
        }
        .frame(width: 540)
        .frame(minHeight: 320, idealHeight: 560, maxHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.fwAccent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Imported “\(report.sourceName)”")
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fwSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let attention = report.needsAttention.count
        let original = "Your original drill wasn't changed."
        switch attention {
        case 0: return "\(original) The converted show is ready to edit."
        case 1: return "\(original) One thing is worth a look before you start."
        default: return "\(original) \(attention) things are worth a look before you start."
        }
    }

    private var savedFiles: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            groupTitle("Saved alongside the show")
            VStack(spacing: 0) {
                ForEach(Array(report.savedFiles.enumerated()), id: \.element) { index, file in
                    if index > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: Tokens.Space.m) {
                        icon(file.role == "Click check" ? "metronome" : file.role.hasPrefix("Recording") ? "waveform" : "music.note.list",
                             tint: Color.fwAccent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.role).font(.system(size: 13, weight: .semibold))
                            Text(file.name).font(.system(size: 12)).foregroundStyle(Color.fwSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, Tokens.Space.m)
                    .accessibilityElement(children: .combine)
                }
            }
            .fwGroup()
        }
    }

    @ViewBuilder
    private func noteGroup(_ title: String, notes: [ImportNote]) -> some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                groupTitle(title)
                VStack(spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().padding(.leading, 44) }
                        NoteRow(note: note) { realignControls(for: note) }
                    }
                }
                .fwGroup()
            }
        }
    }

    private var technical: some View {
        DisclosureGroup(isExpanded: $showsTechnical) {
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                Text(report.technicalText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.fwSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.m)
                    .fwGroup(cornerRadius: Tokens.Radius.panel)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.technicalText, forType: .string)
                } label: { Label("Copy Details", systemImage: "doc.on.doc") }
                    .controlSize(.small)
                    .fwSecondaryButton()
            }
            .padding(.top, Tokens.Space.s)
        } label: {
            Text("Technical details").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fwSecondary)
        }
    }

    /// For the unconfident alignment note: use the converter's guess, rewriting
    /// the count track and click check with it.
    @ViewBuilder
    private func realignControls(for note: ImportNote) -> some View {
        if let offset = note.suggestedOffset, let text = note.suggestedOffsetText, let realignment = report.realignment {
            let files = realignment.clickCheck == nil ? "the count track" : "the count track and click check"
            switch realign {
            case .idle:
                VStack(alignment: .leading, spacing: 6) {
                    Button { apply(offset, with: realignment) } label: { Label("Use This Timing", systemImage: "checkmark") }
                        .controlSize(.small)
                        .fwPrimaryButton()
                    Text("Rewrites \(files) with the music starting at \(text).")
                        .font(.system(size: 11)).foregroundStyle(Color.fwSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Lining up \(files)…").font(.system(size: 11)).foregroundStyle(Color.fwSecondary)
                }
                .padding(.top, 4)
            case .done:
                Label("Done. \(files.prefix(1).uppercased() + files.dropFirst())\(report.recording == nil ? "" : " and the show") now start\(realignment.clickCheck == nil && report.recording == nil ? "s" : "") the music at \(text). Listen to the click check to confirm.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.fwAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.system(size: 11)).foregroundStyle(Color.fwError)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Try Again") { apply(offset, with: realignment) }
                        .controlSize(.small)
                        .fwSecondaryButton()
                }
                .padding(.top, 4)
            }
        }
    }

    private func apply(_ offset: Double, with realignment: ImportReport.Realignment) {
        realign = .running
        Task { @MainActor in
            do {
                try await realignment.apply(offset: offset)
                if report.recording != nil { alignShow?(offset) }
                realign = .done
            } catch {
                realign = .failed(DrillImport.explain(error))
            }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.fwSecondary)
            .padding(.leading, Tokens.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoteRow<Accessory: View>: View {
    let note: ImportNote
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            icon(note.systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title).font(.system(size: 13, weight: .semibold))
                    if note.kind == .changed {
                        Text("Changed")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.fwWarning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.fwWarning.opacity(0.15)))
                    }
                }
                Text(note.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fwSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note.technical)
                accessory
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Tokens.Space.m)
        .accessibilityElement(children: .contain)
    }

    private var tint: Color { note.kind == .info ? Color.fwAccent : Color.fwWarning }
}

/// A small rounded tile holding a symbol, used for each row in the report.
private func icon(_ systemImage: String, tint: Color) -> some View {
    Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15)))
        .accessibilityHidden(true)
}
