import AppKit
import ApplicationServices
import Foundation
import AVFoundation
import Speech
import Darwin
import RayPlacementCore
import SwiftUI

@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    enum PermissionID: String, CaseIterable, Identifiable {
        case accessibility, microphone, speechRecognition, appleEvents, loginItem
        var id: String { rawValue }
        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .appleEvents: return "Automation / Apple Events"
            case .loginItem: return "Launch at Login"
            }
        }
        var explanation: String {
            switch self {
            case .accessibility: return "Used only for selected-text actions, paste, and window controls."
            case .microphone: return "Used only after Dictation is started. Audio is processed locally."
            case .speechRecognition: return "Used by Apple Speech when that dictation engine is selected."
            case .appleEvents: return "Used for the Apple Music and Spotify controls you invoke."
            case .loginItem: return "Lets Lima start automatically when you sign in."
            }
        }
    }

    enum Status: String {
        case granted = "Granted"
        case denied = "Needs attention"
        case unavailable = "Not available"
    }

    @Published private(set) var statuses: [PermissionID: Status] = [:]

    private init() { refresh() }

    func refresh() {
        statuses[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        statuses[.microphone] = microphoneStatus()
        statuses[.speechRecognition] = speechStatus()
        statuses[.appleEvents] = .unavailable
        statuses[.loginItem] = SettingsStore.shared.launchAtLogin ? .granted : .denied
    }

    func request(_ permission: PermissionID) {
        switch permission {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in self.refresh() }
            }
        case .appleEvents:
            openSystemSettings(for: "Privacy_Automation")
        case .loginItem:
            SettingsStore.shared.setLaunchAtLogin(true)
        }
        refresh()
    }

    func openSystemSettings(for anchor: String? = nil) {
        let suffix = anchor.map { "?\($0)" } ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security\(suffix)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .denied
        @unknown default: return .unavailable
        }
    }

    private func speechStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted, .notDetermined: return .denied
        @unknown default: return .unavailable
        }
    }
}

struct RuntimeDiagnosticsSnapshot {
    static let slowOperationThresholdMilliseconds = 1_000
    static let maximumRecentFailures = 5
    static let maximumRecentSlowOperations = 5

    let appUptime: TimeInterval
    let residentMemoryBytes: UInt64?
    let activeTaskCount: Int
    let recentFailures: [LimaTask]
    let recentSlowOperations: [LimaPerformanceSample]
    let provider: AIProvider
    let providerCredentialConfigured: Bool
    let extensionIssueCount: Int
    let dictationEngine: DictationEngine
    let dictationIsActive: Bool

    var providerStatus: String {
        if provider.isCLI {
            return providerCredentialConfigured ? "CLI installed · sign-in checked on request" : "CLI not installed"
        }
        if provider == .openAICompatible {
            return "Custom endpoint · connection checked on request"
        }
        return providerCredentialConfigured
            ? "Credential available · connection checked on request"
            : "Credential not configured"
    }

    static func make(
        startedAt: Date,
        now: Date = Date(),
        residentMemoryBytes: UInt64?,
        activeTasks: [LimaTask],
        recentTasks: [LimaTask],
        performanceSamples: [LimaPerformanceSample],
        provider: AIProvider,
        providerCredentialConfigured: Bool,
        extensionIssueCount: Int,
        dictationEngine: DictationEngine,
        dictationIsActive: Bool
    ) -> RuntimeDiagnosticsSnapshot {
        RuntimeDiagnosticsSnapshot(
            appUptime: max(0, now.timeIntervalSince(startedAt)),
            residentMemoryBytes: residentMemoryBytes,
            activeTaskCount: activeTasks.count,
            recentFailures: Array(recentTasks.filter { $0.state == .failed }.prefix(maximumRecentFailures)),
            recentSlowOperations: Array(performanceSamples.filter {
                $0.milliseconds >= slowOperationThresholdMilliseconds
            }.prefix(maximumRecentSlowOperations)),
            provider: provider,
            providerCredentialConfigured: providerCredentialConfigured,
            extensionIssueCount: max(0, extensionIssueCount),
            dictationEngine: dictationEngine,
            dictationIsActive: dictationIsActive
        )
    }
}

@MainActor
final class DiagnosticsService {
    static let shared = DiagnosticsService()

    private(set) var startedAt = Date()

    private init() {}

    func markAppStarted(at date: Date = Date()) {
        startedAt = date
    }

    func runtimeSnapshot(
        provider: AIProvider,
        providerCredentialConfigured: Bool,
        extensionIssueCount: Int,
        dictationEngine: DictationEngine
    ) -> RuntimeDiagnosticsSnapshot {
        let activeTasks = TaskRegistry.shared.activeTasks
        return RuntimeDiagnosticsSnapshot.make(
            startedAt: startedAt,
            residentMemoryBytes: residentMemoryBytes(),
            activeTasks: activeTasks,
            recentTasks: TaskRegistry.shared.recentTasks,
            performanceSamples: PerformanceMonitor.shared.samples,
            provider: provider,
            providerCredentialConfigured: providerCredentialConfigured,
            extensionIssueCount: extensionIssueCount,
            dictationEngine: dictationEngine,
            dictationIsActive: activeTasks.contains { $0.kind == .dictation }
        )
    }

    private func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

    func export(to destination: URL? = nil) throws -> URL {
        let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        let selectedProvider = AIConversationStore.shared.conversations.first?.provider ?? .openAI
        let credentialConfigured = selectedProvider == .openAICompatible
            || (selectedProvider.isCLI && CLIChatProviderClient.executableURL(for: selectedProvider) != nil)
            || AIProviderCredentialStore.shared.hasAPIKey(for: selectedProvider)
        let extensionIssues = ExtensionLoader().load(prepare: false, registerPackages: false).issues
        let runtime = runtimeSnapshot(
            provider: selectedProvider,
            providerCredentialConfigured: credentialConfigured,
            extensionIssueCount: extensionIssues.count,
            dictationEngine: SettingsStore.shared.dictationEngine
        )
        let values: [String: Any] = [
            "app": [
                "name": "Lima",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "bundle": Bundle.main.bundleIdentifier ?? "unknown"
            ],
            "system": [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architectureName()
            ],
            "permissions": PermissionCenter.shared.statuses.reduce(into: [String: String]()) { result, pair in
                result[pair.key.rawValue] = pair.value.rawValue
            },
            "paths": ["applicationSupport": ApplicationPaths.applicationSupport.path],
            "notes": ["count": NotesStore.shared.notes.count, "persistenceError": NotesStore.shared.lastError ?? ""],
            "dictation": ["count": DictationConversationStore.shared.conversations.count, "persistenceError": DictationConversationStore.shared.lastError ?? ""],
            "clipboard": ["count": ClipboardHistoryService.shared.entries.count, "persistenceError": ClipboardHistoryService.shared.lastError ?? ""],
            "extensions": ["issues": extensionIssues.count],
            "runtime": [
                "appUptimeSeconds": Int(runtime.appUptime),
                "residentMemoryBytes": runtime.residentMemoryBytes.map { NSNumber(value: $0) } ?? NSNull(),
                "activeTaskCount": runtime.activeTaskCount,
                "recentFailedTasks": runtime.recentFailures.map {
                    ["kind": $0.kind.rawValue, "state": $0.state.rawValue, "updatedAt": ISO8601DateFormatter().string(from: $0.updatedAt)]
                },
                "recentSlowOperations": runtime.recentSlowOperations.map {
                    ["operation": $0.operation, "durationMilliseconds": $0.milliseconds, "succeeded": $0.succeeded]
                },
                "provider": [
                    "selected": runtime.provider.rawValue,
                    "credentialConfigured": runtime.providerCredentialConfigured,
                    "connection": "checked on request"
                ],
                "extensionIssueCount": runtime.extensionIssueCount,
                "dictation": [
                    "engine": runtime.dictationEngine.rawValue,
                    "active": runtime.dictationIsActive
                ]
            ],
            "tasks": [
                "active": TaskRegistry.shared.activeTasks.map {
                    ["kind": $0.kind.rawValue, "state": $0.state.rawValue, "startedAt": ISO8601DateFormatter().string(from: $0.startedAt)]
                },
                "recentCount": TaskRegistry.shared.recentTasks.count
            ],
            "performance": PerformanceMonitor.shared.samples.prefix(40).map {
                ["operation": $0.operation, "durationMilliseconds": $0.milliseconds, "succeeded": $0.succeeded]
            },
            "privacy": "Note contents, transcripts, clipboard contents, selected text, shell input and output, provider prompts and responses, and secret values are intentionally omitted."
        ]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
}

private func architectureName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
        let bytes = Array(rawBuffer)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }
}

struct PermissionCenterView: View {
    @ObservedObject var center: PermissionCenter
    var body: some View {
        Form {
            Section("Feature access") {
                ForEach(PermissionCenter.PermissionID.allCases) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: center.statuses[permission] == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(center.statuses[permission] == .granted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                            Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(center.statuses[permission]?.rawValue ?? "Checking…").font(.caption).foregroundStyle(.secondary)
                        Button(center.statuses[permission] == .granted ? "Recheck" : "Request") { center.request(permission) }
                    }
                }
            }
            Section {
                Button("Open macOS Privacy Settings") { center.openSystemSettings() }
                Text("Lima never requests access until a feature needs it, and denied permissions leave the rest of the launcher usable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { center.refresh() }
    }
}
