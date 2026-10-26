import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotStudioModel: ObservableObject {
    @Published var query = ""
    @Published var recognizesText = LimaTestEnvironment.userDefaults.bool(forKey: "lima.screenshot.localOCR") {
        didSet { LimaTestEnvironment.userDefaults.set(recognizesText, forKey: "lima.screenshot.localOCR") }
    }
    @Published private(set) var destination = ScreenshotDestination(
        rawValue: LimaTestEnvironment.userDefaults.string(forKey: "lima.screenshot.destination") ?? ""
    ) ?? .clipboardAndHistory
    @Published var fileFormat = ScreenshotImageFormat(
        rawValue: LimaTestEnvironment.userDefaults.string(forKey: "lima.screenshot.fileFormat") ?? ""
    ) ?? .png {
        didSet { LimaTestEnvironment.userDefaults.set(fileFormat.rawValue, forKey: "lima.screenshot.fileFormat") }
    }
    @Published private(set) var saveFolderName: String? = {
        guard let bookmark = LimaTestEnvironment.userDefaults.data(forKey: "lima.screenshot.saveFolderBookmark") else { return nil }
        return ScreenshotFileDestination.folderName(for: bookmark)
    }()
    @Published private(set) var records: [ScreenshotRecord] = []
    @Published private(set) var targets: [ScreenshotCaptureTargetInfo] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isReady = false
    @Published private(set) var needsScreenRecordingPermission = false
    @Published var message: String?

    private let captureService = ScreenshotCaptureService.shared
    private var store: ScreenshotHistoryStore?
    private var loadingStore = false
    private var searchGeneration = 0

    func selectDestination(_ value: ScreenshotDestination) {
        guard !isWorking else { return }
        if value.includesFile && saveFolderName == nil {
            chooseSaveFolder(selecting: value)
            return
        }
        destination = value
        LimaTestEnvironment.userDefaults.set(value.rawValue, forKey: "lima.screenshot.destination")
    }

    func chooseSaveFolder(selecting pendingDestination: ScreenshotDestination? = nil) {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Screenshot Save Folder"
        panel.message = "Lima saves file-destination captures in this folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let folder = panel.url else { return }
            do {
                let bookmark = try ScreenshotFileDestination.bookmark(for: folder)
                LimaTestEnvironment.userDefaults.set(bookmark, forKey: "lima.screenshot.saveFolderBookmark")
                self.saveFolderName = folder.lastPathComponent
                if let pendingDestination { self.selectDestination(pendingDestination) }
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func prepareStore() {
        if store != nil { refreshHistory(); return }
        guard !loadingStore else { return }
        loadingStore = true
        message = "Preparing screenshot library…"
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotHistoryStore()
                }.value
                store = opened
                isReady = true
                message = nil
                refreshHistory()
            } catch {
                message = error.localizedDescription
            }
            loadingStore = false
        }
    }

    func refreshHistory() {
        guard let store else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let query = query
        Task {
            do {
                let found = try await store.search(query, limit: 200)
                guard generation == searchGeneration else { return }
                records = found
            } catch {
                guard generation == searchGeneration else { return }
                message = error.localizedDescription
            }
        }
    }

    func prepareCaptureTargets() {
        guard isReady, !isWorking else { return }
        guard captureService.hasScreenRecordingPermission else {
            needsScreenRecordingPermission = true
            targets = []
            return
        }
        needsScreenRecordingPermission = false
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                targets = try await captureService.availableTargets()
                    .filter { $0.sourceBundleID != Bundle.main.bundleIdentifier }
                if targets.isEmpty { message = "No eligible displays or windows are available." }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func requestScreenRecordingPermission() {
        _ = captureService.requestScreenRecordingPermission()
        if captureService.hasScreenRecordingPermission {
            prepareCaptureTargets()
        } else {
            needsScreenRecordingPermission = true
            message = "After enabling Screen Recording, reopen Lima if macOS asks you to restart it."
        }
    }

    func capture(_ target: ScreenshotCaptureTarget,
                 beforeCapture: @escaping () -> Void,
                 captureAllowed: @escaping () -> Bool,
                 afterCapture: @escaping (Bool) -> Void,
                 onTakeover: @escaping () -> Void) {
        guard !isWorking else { return }
        let selectedDestination = destination
        let selectedFormat = fileFormat
        let folderBookmark = LimaTestEnvironment.userDefaults.data(forKey: "lima.screenshot.saveFolderBookmark")
        if selectedDestination.includesFile && folderBookmark == nil {
            message = ScreenshotFileDestination.DestinationError.folderUnavailable.localizedDescription
            // Region selection has already hidden Studio. Restore its error UI
            // even when capture fails before the asynchronous work starts.
            afterCapture(false)
            return
        }
        guard let store else {
            message = "The screenshot library is not ready. Reopen Screenshot Studio and try again."
            afterCapture(false)
            return
        }
        isWorking = true
        message = nil
        beforeCapture()
        Task {
            do {
                // Allow the picker window to leave the compositor before the
                // selected display is sampled; selection is still revalidated.
                try await Task.sleep(nanoseconds: 180_000_000)
                guard captureAllowed() else { stopCaptureForTakeover(onTakeover); return }
                let image = try await captureService.capture(target)
                guard captureAllowed() else { stopCaptureForTakeover(onTakeover); return }
                var failures: [String] = []
                if selectedDestination.includesHistory {
                    do {
                        _ = try await store.importImage(
                            image.pngData, format: .png, metadata: image.metadata,
                            recognizeText: recognizesText
                        )
                    } catch {
                        failures.append("History: \(error.localizedDescription)")
                    }
                    refreshHistory()
                }
                guard captureAllowed() else { stopCaptureForTakeover(onTakeover); return }
                if selectedDestination.includesFile, let folderBookmark {
                    do {
                        let png = image.pngData
                        _ = try await Task.detached(priority: .userInitiated) {
                            try ScreenshotFileDestination.save(
                                png, format: selectedFormat, bookmark: folderBookmark
                            )
                        }.value
                    } catch {
                        failures.append("File: \(error.localizedDescription)")
                    }
                }
                guard captureAllowed() else { stopCaptureForTakeover(onTakeover); return }
                if selectedDestination.includesClipboard && !ScreenshotClipboard.copyPNG(image.pngData) {
                    failures.append("Clipboard: The image could not be copied as PNG data.")
                }
                isWorking = false
                message = failures.isEmpty ? nil : failures.joined(separator: "  ")
                afterCapture(failures.isEmpty)
            } catch {
                guard captureAllowed() else { stopCaptureForTakeover(onTakeover); return }
                isWorking = false
                message = error.localizedDescription
                afterCapture(false)
            }
        }
    }

    private func stopCaptureForTakeover(_ onTakeover: () -> Void) {
        isWorking = false
        message = "Capture stopped because the app, display, or clipboard changed. An earlier destination may already contain the image."
        onTakeover()
    }

    func copy(_ record: ScreenshotRecord) {
        guard let store else { return }
        Task {
            do {
                let (data, format) = try await store.imageData(for: record.id)
                guard ScreenshotClipboard.copy(data, format: format) else {
                    throw ScreenshotCaptureError.clipboardUnavailable
                }
                message = "Copied image to clipboard"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func reveal(_ record: ScreenshotRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.imageURL])
    }

    func setTags(_ tags: [String], for record: ScreenshotRecord) {
        guard let store else { return }
        Task {
            do {
                try await store.setTags(tags, for: record.id)
                refreshHistory()
                message = "Updated screenshot tags"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func export(_ record: ScreenshotRecord, as format: ScreenshotImageFormat) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.title = "Export Screenshot"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = "Lima Screenshot \(record.id.uuidString).\(format.fileExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    // The destination comes only from the user's Save panel.
                    try await Task.detached(priority: .userInitiated) {
                        let (sourceData, sourceFormat) = try await store.imageData(for: record.id)
                        let output = try ScreenshotImageExport.data(
                            sourceData, sourceFormat: sourceFormat, destinationFormat: format
                        )
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try output.write(to: url, options: .atomic)
                    }.value
                    self?.message = "Exported screenshot"
                } catch {
                    self?.message = error.localizedDescription
                }
            }
        }
    }

    func togglePin(_ record: ScreenshotRecord) {
        guard let store else { return }
        Task {
            do {
                try await store.setPinned(!record.isPinned, for: record.id)
                refreshHistory()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func delete(_ record: ScreenshotRecord) {
        guard let store else { return }
        Task {
            do {
                try await store.delete(id: record.id)
                refreshHistory()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

@MainActor
final class ScreenshotStudioWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotStudioWindowController()

    private let model = ScreenshotStudioModel()
    private let regionSelection = ScreenshotRegionSelectionController()
    private var panel: NSPanel?
    private var returnApplication: NSRunningApplication?
    private var captureContext: ScreenshotCaptureContext?

    func present(returningTo application: NSRunningApplication? = nil) {
        guard !model.isWorking else { return }
        regionSelection.dismiss(notifyCancel: false)
        captureContext = nil
        returnApplication = application?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : application
        if panel == nil {
            let panel = ScreenshotStudioPanel(
                contentRect: NSRect(x: 0, y: 0, width: 730, height: 570),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            panel.title = "Screenshot Studio"
            panel.minSize = NSSize(width: 620, height: 440)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ScreenshotStudioView(
                model: model,
                selectRegion: { [weak self] in self?.startRegionSelection() },
                beforeCapture: { [weak self] in self?.beginCapture() },
                captureAllowed: { [weak self] in self?.captureContext?.isCurrent == true },
                afterCapture: { [weak self] succeeded in self?.finishCapture(succeeded: succeeded) },
                onTakeover: { [weak self] in self?.stopForTakeover() }
            ))
            panel.center()
            self.panel = panel
        }
        model.prepareStore()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRegionSelection() {
        guard model.isReady, !model.isWorking else { return }
        beginCapture()
        _ = regionSelection.present(
            displays: model.targets,
            onSelect: { [weak self] target in
                guard let self else { return }
                guard self.captureContext?.isCurrent == true else {
                    self.stopForTakeover()
                    return
                }
                self.model.capture(
                    target, beforeCapture: {},
                    captureAllowed: { [weak self] in self?.captureContext?.isCurrent == true },
                    afterCapture: { [weak self] succeeded in self?.finishCapture(succeeded: succeeded) },
                    onTakeover: { [weak self] in self?.stopForTakeover() }
                )
            },
            onCancel: { [weak self] in
                guard let self else { return }
                guard self.captureContext?.isCurrent == true else {
                    self.stopForTakeover()
                    return
                }
                self.captureContext = nil
                self.panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            },
            onTakeover: { [weak self] in self?.stopForTakeover() }
        )
    }

    private func beginCapture() {
        captureContext = ScreenshotCaptureContext(sourceProcessID: returnApplication?.processIdentifier)
        panel?.orderOut(nil)
    }

    private func stopForTakeover() {
        captureContext = nil
        regionSelection.dismiss(notifyCancel: false)
        panel?.orderOut(nil)
        returnApplication = nil
    }

    private func finishCapture(succeeded: Bool) {
        captureContext = nil
        if succeeded {
            panel?.orderOut(nil)
            returnApplication?.activate(options: [.activateIgnoringOtherApps])
        } else {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class ScreenshotStudioPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

private enum ScreenshotStudioSheet: Identifiable {
    case preview(ScreenshotRecord)
    case tags(ScreenshotRecord)

    var id: String {
        switch self {
        case .preview(let record): return "preview-\(record.id.uuidString)"
        case .tags(let record): return "tags-\(record.id.uuidString)"
        }
    }
}

@MainActor
private struct ScreenshotStudioView: View {
    @ObservedObject var model: ScreenshotStudioModel
    let selectRegion: () -> Void
    let beforeCapture: () -> Void
    let captureAllowed: () -> Bool
    let afterCapture: (Bool) -> Void
    let onTakeover: () -> Void

    @State private var showingCaptureTargets = false
    @State private var pendingDelete: ScreenshotRecord?
    @State private var activeSheet: ScreenshotStudioSheet?
    @State private var tagDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screenshot Studio").font(.title2.weight(.semibold))
                    Text("Capture a region, window, or display, or copy a saved image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(showingCaptureTargets ? "History" : "Capture…") {
                    showingCaptureTargets.toggle()
                    if showingCaptureTargets { model.prepareCaptureTargets() }
                    else { model.refreshHistory() }
                }
                .disabled(model.isWorking || !model.isReady)
            }

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenshot-studio-message")
            }

            if showingCaptureTargets {
                captureContent
            } else {
                historyContent
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview(let record):
                VStack(alignment: .leading, spacing: 12) {
                    Text(record.windowTitle ?? record.sourceApplication ?? "Screenshot")
                        .font(.headline)
                    if let image = NSImage(contentsOf: record.imageURL) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("The saved screenshot is unavailable.")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Copy Image") { model.copy(record) }
                        Button("Done") { activeSheet = nil }
                    }
                }
                .padding(20)
                .frame(minWidth: 500, idealWidth: 820, minHeight: 340, idealHeight: 600)
            case .tags(let record):
                VStack(alignment: .leading, spacing: 14) {
                    Text("Edit Screenshot Tags").font(.headline)
                    Text("Separate tags with commas.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("report, design, reference", text: $tagDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Cancel") { activeSheet = nil }
                        Button("Save Tags") {
                            let tags = tagDraft.split(separator: ",", omittingEmptySubsequences: false)
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            model.setTags(tags, for: record)
                            activeSheet = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 440)
            }
        }
        .confirmationDialog(
            "Delete this screenshot from history?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete Screenshot", role: .destructive) {
                if let pendingDelete { model.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.needsScreenRecordingPermission {
                Text("Screen Recording access is required to list and capture windows or displays.")
                    .foregroundStyle(.secondary)
                Button("Enable Screen Recording") {
                    model.requestScreenRecordingPermission()
                }
            } else {
                HStack {
                    Text("Choose a region, window, or display").font(.headline)
                    Spacer()
                    Button("Select Region…", action: selectRegion)
                        .disabled(model.isWorking || !model.targets.contains(where: {
                            if case .display = $0.kind { return true }
                            return false
                        }))
                    Button("Refresh") { model.prepareCaptureTargets() }
                        .disabled(model.isWorking)
                }
                HStack(spacing: 12) {
                    Picker("Destination", selection: Binding(
                        get: { model.destination },
                        set: { model.selectDestination($0) }
                    )) {
                        ForEach(ScreenshotDestination.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                    Spacer()
                    if model.destination.includesFile {
                        Picker("Format", selection: $model.fileFormat) {
                            ForEach(ScreenshotImageFormat.allCases, id: \.self) { format in
                                Text(format == .png ? "PNG" : "JPEG").tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
                if model.destination.includesFile {
                    HStack {
                        Text("Save folder: \(model.saveFolderName ?? "Not selected")")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose Folder…") { model.chooseSaveFolder() }
                            .disabled(model.isWorking)
                    }
                }
                Toggle("Recognize text locally for future History captures", isOn: $model.recognizesText)
                    .font(.caption)
                    .disabled(!model.destination.includesHistory)
                    .help("Optional Vision OCR runs on this Mac after capture; recognized text is saved only in Screenshot History.")
                if model.isWorking {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.targets) { target in
                                Button {
                                    model.capture(
                                        target.target,
                                        beforeCapture: beforeCapture,
                                        captureAllowed: captureAllowed,
                                        afterCapture: afterCapture,
                                        onTakeover: onTakeover
                                    )
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: target.kind == .display ? "display" : "macwindow")
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(target.title).lineLimit(1)
                                            if let app = target.sourceApplication {
                                                Text(app).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text("Capture").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search screenshots by app, window, tag, or recognized text", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query) { _ in model.refreshHistory() }
            if model.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No screenshots yet").font(.headline)
                    Text("Choose Capture to save and copy a region, window, or display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.records) { record in
                            historyRow(record)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ record: ScreenshotRecord) -> some View {
        HStack(spacing: 12) {
            if let thumbnailURL = record.thumbnailURL,
               let thumbnail = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .frame(width: 100, height: 64)
                    .background(.black.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo").frame(width: 100, height: 64)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.windowTitle ?? record.sourceApplication ?? "Screenshot")
                    .lineLimit(1).font(.subheadline.weight(.medium))
                Text("\(record.category.rawValue.capitalized) · \(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(record.capturedAt, style: .date)
                    .font(.caption2).foregroundStyle(.secondary)
                if !record.tags.isEmpty {
                    Text(record.tags.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Copy") { model.copy(record) }
            Button {
                model.togglePin(record)
            } label: {
                Image(systemName: record.isPinned ? "pin.fill" : "pin")
            }
            .help(record.isPinned ? "Unpin" : "Pin")
            Menu {
                Button("Preview") { activeSheet = .preview(record) }
                Button("Edit Tags…") {
                    tagDraft = record.tags.joined(separator: ", ")
                    activeSheet = .tags(record)
                }
                Divider()
                Button("Export PNG…") { model.export(record, as: .png) }
                Button("Export JPEG…") { model.export(record, as: .jpeg) }
                Button("Reveal in Finder") { model.reveal(record) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = record }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Screenshot actions")
        }
        .padding(8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }
}
