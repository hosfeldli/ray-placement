import CoreAudio
import Foundation

/// A private, output-only Core Audio tap used solely to calculate a transient
/// RMS level for the compact now-playing rail. Samples are never retained,
/// written, transcribed, or exposed outside this process.
final class SystemAudioLevelMonitor {
    private let queue = DispatchQueue(label: "dev.lima.output-level", qos: .userInteractive)
    private let onLevel: @Sendable (Double) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(onLevel: @escaping @Sendable (Double) -> Void) {
        self.onLevel = onLevel
    }

    @available(macOS 14.2, *)
    func start() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Lima Now Playing Meter"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return false }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lima Now Playing Meter",
            kAudioAggregateDeviceUIDKey: "dev.lima.output-meter.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var sum: Double = 0
            var count = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                let samples = data.assumingMemoryBound(to: Float32.self)
                for index in 0..<sampleCount {
                    let sample = Double(samples[index])
                    guard sample.isFinite else { continue }
                    sum += sample * sample
                    count += 1
                }
            }
            guard count > 0 else { return }
            let rms = sqrt(sum / Double(count))
            // Musical peaks occupy a small numerical range. Log-like scaling
            // keeps quiet passages visible without pinning normal tracks at 1.
            self.onLevel(min(1, max(0, sqrt(rms) * 2.6)))
        }
        guard status == noErr, let ioProcID,
              AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
