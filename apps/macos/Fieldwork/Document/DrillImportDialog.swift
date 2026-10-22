import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DrillConvert

/// The choices in the import dialog, and the conversion they start. Every file
/// comes from an open or save panel, so a sandboxed Fieldwork may read and
/// write it. The converter itself only sees copies in Fieldwork's temporary
/// folder; finished files are saved here, after every conversion succeeded,
/// so a failure never leaves a half-finished set of files behind.
@MainActor
final class DrillImportModel: ObservableObject {
    let source: URL

    // The show.
    @Published var showDestination: URL?
    @Published var allowApproximations = false
    @Published var pageMap: URL?
    @Published var flipX = false
    @Published var flipY = false
    @Published var stepsPerUnit = ""

    // The MusicXML count track.
    @Published var exportMusicXML = false
    @Published var musicXMLDestination: URL?
    @Published var audio: URL?
    @Published var audioOffset = ""
    @Published var followAudio = false
    @Published var clickCheck = false
    @Published var clickCheckDestination: URL?

    /// What is running, while a conversion runs.
    @Published private(set) var progress: String?
    @Published var error: String?

    private var task: Task<Void, Never>?
    /// Called with the saved show and the banner text for it.
    var finished: ((URL, String) -> Void)?

    init(source: URL) {
        self.source = source
    }

    var name: String { source.deletingPathExtension().lastPathComponent }
    var isConverting: Bool { progress != nil }

    /// The first thing still missing before Convert can run, if any.
    var missing: String? {
        if showDestination == nil { return "Choose where to save the show." }
        if !stepsPerUnit.trimmingCharacters(in: .whitespaces).isEmpty && Self.number(stepsPerUnit).map({ $0 > 0 }) != true {
            return "Steps per unit must be a number greater than 0."
        }
        guard exportMusicXML else { return nil }
        if musicXMLDestination == nil { return "Choose where to save the MusicXML file." }
        if !audioOffset.trimmingCharacters(in: .whitespaces).isEmpty && Self.number(audioOffset) == nil {
            return "The audio offset must be a number of seconds."
        }
        if (followAudio || clickCheck) && audio == nil { return "Choose the recording (.wav)." }
        if clickCheck && clickCheckDestination == nil { return "Choose where to save the click check." }
        return nil
    }

    var options: ConverterOptions {
        var options = ConverterOptions()
        options.allowApproximations = allowApproximations
        options.pageMap = pageMap
        options.flipX = flipX
        options.flipY = flipY
        options.stepsPerUnit = Self.number(stepsPerUnit)
        options.audio = audio
        options.audioOffset = Self.number(audioOffset)
        options.followAudio = followAudio && audio != nil
        options.clickCheck = clickCheck && audio != nil
        return options
    }

    /// Accepts "1.6" and "1,6"; empty means "not given".
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(trimmed).flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: Choosing files

    func chooseShowDestination() {
        showDestination = save(suggesting: "\(name).fieldwork", type: UTType(FieldworkDocument.typeIdentifier) ?? .data) ?? showDestination
    }

    func chooseMusicXMLDestination() {
        let type = UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml
        musicXMLDestination = save(suggesting: "\(name).musicxml", type: type) ?? musicXMLDestination
    }

    func chooseClickCheckDestination() {
        clickCheckDestination = save(suggesting: "\(name) click check.wav", type: .wav) ?? clickCheckDestination
    }

    func chooseAudio() { audio = open(type: .wav, prompt: "Choose the show’s recording") ?? audio }

    func choosePageMap() { pageMap = open(type: .json, prompt: "Choose a page map") ?? pageMap }

    private func save(suggesting fileName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = fileName
        panel.directoryURL = showDestination?.deletingLastPathComponent() ?? source.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func open(type: UTType, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.message = prompt
        panel.directoryURL = source.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Converting

    func convert() {
        guard !isConverting, missing == nil, let showDestination = self.showDestination else { return }
        if NSDocumentController.shared.document(for: showDestination) != nil {
            error = "“\(showDestination.lastPathComponent)” is open. Close it, or save the show under another name."
            return
        }
        error = nil
        let options = self.options
        let musicXML = exportMusicXML ? musicXMLDestination : nil
        let click = options.clickCheck ? clickCheckDestination : nil
        task = Task { [source] in
            do {
                let service = ThreeDUConverterService()
                progress = "Converting the drill…"
                let show = try await service.convert(source, to: .fieldwork, options: options)
                var score: ConverterResult?
                if musicXML != nil {
                    progress = options.audio == nil ? "Writing the MusicXML count track…" : "Aligning the count track with the recording…"
                    score = try await service.convert(source, to: .musicxml, options: options)
                }
                progress = "Saving…"
                var saved: [String] = []
                try Self.write(show.data, to: showDestination)
                if let musicXML, let score {
                    try Self.write(score.data, to: musicXML)
                    saved.append("Saved the count track as “\(musicXML.lastPathComponent)”.")
                }
                if let click, let wav = score?.clickCheck {
                    try Self.write(wav, to: click)
                    saved.append("Saved the click check as “\(click.lastPathComponent)”.")
                }
                progress = nil
                let warnings = show.warnings + (score?.warnings ?? [])
                finished?(showDestination, DrillImport.notice(source: source, warnings: warnings, extras: saved))
            } catch ConverterError.cancelled {
                progress = nil
            } catch {
                progress = nil
                self.error = DrillImport.explain(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) } catch {
            throw NSError(domain: "org.fieldwork", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” could not be saved: \(error.localizedDescription)",
            ])
        }
    }
}

/// Options for importing a `.3du` drill, shown before anything is converted.
struct DrillImportView: View {
    @ObservedObject var model: DrillImportModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Drill").font(.system(size: 20, weight: .bold))
                Text(model.source.lastPathComponent)
                    .foregroundStyle(Color.fwSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], Tokens.Space.xl)

            Form {
                SwiftUI.Section {
                    fileRow("Save as", model.showDestination, placeholder: "Not chosen", choose: model.chooseShowDestination)
                    Toggle("Accept approximations", isOn: $model.allowApproximations)
                } header: {
                    Text("Fieldwork show")
                } footer: {
                    Text("Without approximations, the import stops and lists anything it could not convert exactly, such as sets inferred from motion.")
                }

                SwiftUI.Section {
                    fileRow("Page map", model.pageMap, placeholder: "Sets from the drill", choose: model.choosePageMap, clear: { model.pageMap = nil })
                    Toggle("Mirror side to side", isOn: $model.flipX)
                    Toggle("Mirror front to back", isOn: $model.flipY)
                    TextField("Steps per unit", text: $model.stepsPerUnit, prompt: Text("From the drill"))
                } header: {
                    Text("Sets and orientation")
                } footer: {
                    Text("Change these only when the drill imports wrong. A page map is a JSON list of {\"name\", \"start_count\", \"is_subset\"} that replaces the drill’s sets. Steps per unit is 1.6 for yards at 8 to 5.")
                }

                SwiftUI.Section {
                    Toggle("Also export a MusicXML count track", isOn: $model.exportMusicXML)
                    if model.exportMusicXML {
                        fileRow("Save as", model.musicXMLDestination, placeholder: "Not chosen", choose: model.chooseMusicXMLDestination)
                        fileRow("Recording", model.audio, placeholder: "None", choose: model.chooseAudio, clear: {
                            model.audio = nil
                            model.followAudio = false
                            model.clickCheck = false
                        })
                        TextField("Audio offset (seconds)", text: $model.audioOffset, prompt: Text(model.audio == nil ? "0" : "Automatic"))
                        Toggle("Follow the recording beat by beat", isOn: $model.followAudio)
                            .disabled(model.audio == nil)
                        Toggle("Save a click check", isOn: $model.clickCheck)
                            .disabled(model.audio == nil)
                        if model.clickCheck {
                            fileRow("Click check", model.clickCheckDestination, placeholder: "Not chosen", choose: model.chooseClickCheckDestination)
                        }
                    }
                } header: {
                    Text("MusicXML")
                } footer: {
                    if model.exportMusicXML {
                        Text("A click track with the drill’s measures, tempos, rehearsal marks and sets, for notation software or a DAW. With a recording (.wav), count 0 is aligned to it; follow it beat by beat for live performances. The click check is the recording with a click on every aligned beat, to check the alignment by ear.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isConverting)

            if let error = model.error {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.fwWarning)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(.horizontal, Tokens.Space.xl)
            }

            HStack(spacing: Tokens.Space.s) {
                if let progress = model.progress {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(Color.fwSecondary)
                } else if let missing = model.missing {
                    Text(missing).font(.caption).foregroundStyle(Color.fwSecondary)
                }
                Spacer()
                Button("Cancel") {
                    if model.isConverting { model.cancel() } else { close() }
                }
                .keyboardShortcut(.cancelAction)
                .fwSecondaryButton()
                Button("Convert") { model.convert() }
                    .keyboardShortcut(.defaultAction)
                    .fwPrimaryButton()
                    .disabled(model.missing != nil || model.isConverting)
            }
            .controlSize(.large)
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.m)
        }
        .frame(width: 540)
        .frame(minHeight: 520, idealHeight: 640)
    }

    /// A chosen file with Choose… (and Clear, when the file is optional).
    private func fileRow(_ title: String, _ url: URL?, placeholder: String, choose: @escaping () -> Void, clear: (() -> Void)? = nil) -> some View {
        LabeledContent(title) {
            HStack(spacing: Tokens.Space.s) {
                Text(url?.lastPathComponent ?? placeholder)
                    .foregroundStyle(url == nil ? Color.fwSecondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url?.path ?? "")
                if let clear, url != nil {
                    Button("Clear", action: clear)
                }
                Button("Choose…", action: choose)
            }
        }
    }
}

/// One import dialog per drill, in its own window, so the Welcome window and
/// open shows stay usable. Closing it cancels a running conversion.
final class DrillImportWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [URL: DrillImportWindowController] = [:]
    private let model: DrillImportModel

    @MainActor
    static func present(source: URL, finished: @escaping (URL, String) -> Void) {
        if let existing = open[source] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DrillImportWindowController(source: source)
        controller.model.finished = { [weak controller] show, notice in
            controller?.close()
            finished(show, notice)
        }
        open[source] = controller
        controller.showWindow(nil)
    }

    @MainActor
    private init(source: URL) {
        model = DrillImportModel(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Import Drill"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(rootView: DrillImportView(model: model) { [weak self] in self?.close() })
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 540, height: 640))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.cancel()
            Self.open[model.source] = nil
        }
    }
}
