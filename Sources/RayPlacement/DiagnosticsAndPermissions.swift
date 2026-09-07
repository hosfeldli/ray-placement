import AppKit
import ApplicationServices
import Foundation
import AVFoundation
import Speech
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

@MainActor
final class DiagnosticsService {
    static let shared = DiagnosticsService()

    private init() {}

    func export(to destination: URL? = nil) throws -> URL {
        let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
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
            "extensions": ["issues": ExtensionLoader().load().issues.count],
            "privacy": "Note contents, transcripts, clipboard contents, selected text, API secrets, SQL credentials, and tokens are intentionally omitted."
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
