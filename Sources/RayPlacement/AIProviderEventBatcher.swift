import Foundation

/// Consumes provider events off MainActor and delivers ordered, coalesced batches
/// to presentation. Adjacent text/reasoning deltas merge without reordering a
/// change from reasoning to writing or delaying terminal and approval events.
enum AIProviderEventBatcher {
    static let maximumEventsPerBatch = 128

    static func batches(
        _ upstream: AsyncThrowingStream<AIChatStreamEvent, Error>,
        interval: Duration = .milliseconds(33)
    ) -> AsyncThrowingStream<[AIChatStreamEvent], Error> {
        AsyncThrowingStream { continuation in
            let buffer = Buffer(continuation: continuation, interval: interval)
            let reader = Task.detached(priority: .userInitiated) {
                do {
                    for try await event in upstream {
                        guard !Task.isCancelled else { break }
                        await buffer.accept(event)
                    }
                    await buffer.finish()
                } catch {
                    await buffer.fail(error)
                }
            }
            continuation.onTermination = { @Sendable _ in reader.cancel() }
        }
    }

    private actor Buffer {
        private let continuation: AsyncThrowingStream<[AIChatStreamEvent], Error>.Continuation
        private let interval: Duration
        private var pending: [AIChatStreamEvent] = []
        private var timer: Task<Void, Never>?
        private var finished = false

        init(
            continuation: AsyncThrowingStream<[AIChatStreamEvent], Error>.Continuation,
            interval: Duration
        ) {
            self.continuation = continuation
            self.interval = interval
        }

        func accept(_ event: AIChatStreamEvent) {
            guard !finished else { return }
            pending.append(event)
            switch event {
            case .textDelta, .reasoningSummaryDelta:
                if pending.count >= AIProviderEventBatcher.maximumEventsPerBatch {
                    flush()
                } else if timer == nil {
                    timer = Task {
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled else { return }
                        flush()
                    }
                }
            default:
                // Status, tool, approval, and terminal events must not wait for
                // the batching timer or overtake preceding visible text.
                flush()
            }
        }

        func finish() {
            guard !finished else { return }
            flush()
            finished = true
            continuation.finish()
        }

        func fail(_ error: Error) {
            guard !finished else { return }
            flush()
            finished = true
            continuation.finish(throwing: error)
        }

        private func flush() {
            timer?.cancel()
            timer = nil
            guard !pending.isEmpty else { return }
            continuation.yield(Self.coalesce(pending))
            pending.removeAll(keepingCapacity: true)
        }

        private static func coalesce(_ events: [AIChatStreamEvent]) -> [AIChatStreamEvent] {
            var result: [AIChatStreamEvent] = []
            var textChunks: [String] = []
            var reasoningChunks: [String] = []

            func emitText() {
                guard !textChunks.isEmpty else { return }
                result.append(.textDelta(textChunks.joined()))
                textChunks.removeAll(keepingCapacity: true)
            }
            func emitReasoning() {
                guard !reasoningChunks.isEmpty else { return }
                result.append(.reasoningSummaryDelta(reasoningChunks.joined()))
                reasoningChunks.removeAll(keepingCapacity: true)
            }

            for event in events {
                switch event {
                case .textDelta(let value):
                    emitReasoning()
                    textChunks.append(value)
                case .reasoningSummaryDelta(let value):
                    emitText()
                    reasoningChunks.append(value)
                default:
                    emitText()
                    emitReasoning()
                    result.append(event)
                }
            }
            emitText()
            emitReasoning()
            return result
        }
    }
}
