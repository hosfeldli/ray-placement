#if DEBUG
import SwiftUI

enum AIChatVisualScenario: String, CaseIterable {
    case empty = "ai-empty"
    case conversation = "ai-conversation"
    case markdown = "ai-markdown"
    case streaming = "ai-streaming"
    case approval = "ai-approval"
    case failure = "ai-failure"
    case manyChats = "ai-many-chats"

    var title: String {
        switch self {
        case .empty: return "AI Chat — Empty"
        case .conversation: return "AI Chat — Conversation"
        case .markdown: return "AI Chat — Markdown"
        case .streaming: return "AI Chat — Streaming + Reasoning"
        case .approval: return "AI Chat — Tool Approval"
        case .failure: return "AI Chat — Request Failure"
        case .manyChats: return "AI Chat — Many Conversations"
        }
    }
}

struct AIChatVisualPreview: View {
    let scenario: AIChatVisualScenario
    @StateObject private var model: AIChatViewModel

    init(scenario: AIChatVisualScenario) {
        self.scenario = scenario
        _model = StateObject(wrappedValue: AIChatVisualFixtures.model(for: scenario))
    }

    var body: some View {
        AIChatWorkspaceView(model: model)
            .overlay(alignment: .topTrailing) {
                Label("TEST DATA", systemImage: "testtube.2")
                    .limaFont(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.orange, in: Capsule())
                    .padding(16)
                    .accessibilityLabel("Test data")
            }
            .accessibilityIdentifier("ai-visual-\(scenario.rawValue)")
    }
}

struct AIChatVisualLab: View {
    private enum Appearance: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @State private var scenario: AIChatVisualScenario = .conversation
    @State private var appearance: Appearance = .system

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Lima UI Lab", systemImage: "testtube.2")
                    .limaFont(.headline.weight(.semibold))
                    .foregroundStyle(LimaTheme.textPrimary)
                    .padding(.bottom, 4)
                Text("AI Chat")
                    .limaFont(.caption.weight(.bold))
                    .foregroundStyle(LimaTheme.textTertiary)
                    .tracking(0.9)

                ForEach(AIChatVisualScenario.allCases, id: \.self) { candidate in
                    Button {
                        scenario = candidate
                    } label: {
                        Text(candidate.title.replacingOccurrences(of: "AI Chat — ", with: ""))
                            .limaFont(.callout.weight(scenario == candidate ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .limaSelection(scenario == candidate, radius: LimaRadius.control)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Label("Fixture transport", systemImage: "network.slash")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Text("No credentials or network requests")
                    .limaFont(.caption2)
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(14)
            .frame(width: 230)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(LimaTheme.surfaceSecondary)

            VStack(spacing: 0) {
                AIChatVisualPreview(scenario: scenario)
                    .id(scenario.rawValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 12) {
                    Text(scenario.title)
                        .limaFont(.caption.weight(.semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Spacer()
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 115)
                    Text("TEST DATA")
                        .limaFont(.caption2.weight(.bold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.orange, in: Capsule())
                }
                .padding(.horizontal, 16)
                .frame(height: 42)
                .background(LimaTheme.surfaceRaised)
                .overlay(alignment: .top) { GlassHairline() }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .background(LimaTheme.fieldBackground)
    }
}

@MainActor
private enum AIChatVisualFixtures {
    static func model(for scenario: AIChatVisualScenario) -> AIChatViewModel {
        let conversations = fixtureConversations(for: scenario)
        let mcpServer = fixtureMCPServer()
        let model = AIChatViewModel(
            store: AIConversationStore(fixtures: conversations),
            credentials: AIChatCredentialStore(configuration: .fixture),
            mcpStore: MCPServerStore(fixtures: [mcpServer]),
            nativeToolStore: LimaAIToolStore(fixtures: ["search_files", "get_lima_status"]),
            transport: FixtureAITransport.standard
        )

        switch scenario {
        case .streaming:
            model.applyVisualFixture(isStreaming: true)
        case .approval:
            model.applyVisualFixture(
                pendingApproval: AIToolApprovalRequest(
                    localCallID: "fixture-call-1",
                    localToolID: "open_lima_settings",
                    serverLabel: "Lima",
                    toolName: "open_lima_settings",
                    arguments: "{}"
                )
            )
        case .failure:
            model.applyVisualFixture(
                streamError: "The provider rejected this fixture request. Invalid reasoning effort: minimal.",
                diagnostics: [AIChatDiagnostic(
                    stage: .transport,
                    endpoint: "/v1/responses",
                    httpStatus: 400,
                    model: "gpt-5.4",
                    errorCode: "invalid_request_error",
                    errorParameter: "reasoning.effort",
                    message: "Invalid reasoning effort: minimal"
                )],
                showsDiagnostics: true
            )
        default:
            break
        }
        return model
    }

    private static func fixtureConversations(for scenario: AIChatVisualScenario) -> [AIConversation] {
        switch scenario {
        case .empty:
            return []
        case .markdown:
            return [markdownConversation]
        case .streaming:
            return [streamingConversation]
        case .approval:
            return [approvalConversation]
        case .failure:
            return [failureConversation]
        case .manyChats:
            return manyConversations
        case .conversation:
            return [normalConversation, earlierConversation]
        }
    }

    private static var normalConversation: AIConversation {
        AIConversation(
            title: "Publish Lima 3.13.10",
            updatedAt: Date(),
            model: "gpt-5.4",
            reasoningEffort: .medium,
            messages: [
                AIChatMessage(role: .user, text: "Why did the updater stop returning an answer?"),
                AIChatMessage(
                    role: .assistant,
                    text: "The request can fail before visible text arrives when a model receives an unsupported reasoning level or an authenticated MCP tool uses the wrong field. Lima now keeps the failed turn in the transcript and shows a safe failure summary.",
                    reasoningSummary: "Checked the request capability profile and the remote MCP payload.",
                    activities: completedActivities
                )
            ]
        )
    }

    private static var markdownConversation: AIConversation {
        AIConversation(
            title: "AI Markdown Reader",
            updatedAt: Date(),
            model: "gpt-5.4",
            reasoningEffort: .high,
            messages: [
                AIChatMessage(role: .user, text: "Show the UI regression checklist."),
                AIChatMessage(
                    role: .assistant,
                    text: """
                    # AI regression checklist

                    > Run deterministic fixtures before a release. They never contact OpenAI.

                    ## Required states
                    - Normal conversation
                    - Streaming + reasoning
                    - Tool approval
                    - API failure

                    | Surface | Fixture | Result |
                    | --- | --- | --- |
                    | AI Chat | `ai-markdown` | Rich blocks |
                    | AI Chat | `ai-failure` | Visible error |

                    ```swift
                    let transport = FixtureAITransport()
                    ```
                    """,
                    reasoningSummary: "Organized the state matrix by visible outcome.",
                    activities: completedActivities
                )
            ]
        )
    }

    private static var streamingConversation: AIConversation {
        AIConversation(
            title: "Investigate streaming transport",
            updatedAt: Date(),
            model: "gpt-5.4",
            reasoningEffort: .high,
            messages: [
                AIChatMessage(role: .user, text: "Trace the response stream."),
                AIChatMessage(
                    role: .assistant,
                    text: "The parser reconstructed the multiline event with an actual newline and is now",
                    reasoningSummary: "Inspecting the raw SSE frame boundary.",
                    activities: [
                        AIAgentActivity(kind: .started, title: "Started", detail: "Responses stream", startedAt: fixtureNow.addingTimeInterval(-4), endedAt: fixtureNow.addingTimeInterval(-4), completed: true),
                        AIAgentActivity(kind: .reasoningSummary, title: "Reasoning", detail: "Inspecting SSE framing", startedAt: fixtureNow.addingTimeInterval(-3), endedAt: fixtureNow.addingTimeInterval(-2), completed: true),
                        AIAgentActivity(kind: .toolStarted, title: "Search Files", detail: "Lima", startedAt: fixtureNow.addingTimeInterval(-1), endedAt: fixtureNow, duration: 1, completed: false)
                    ]
                )
            ]
        )
    }

    private static var approvalConversation: AIConversation {
        AIConversation(
            title: "Open Lima settings",
            updatedAt: Date(),
            model: "gpt-5.4",
            messages: [
                AIChatMessage(role: .user, text: "Open the app settings."),
                AIChatMessage(
                    role: .assistant,
                    text: "I need approval before opening a Lima window.",
                    activities: [
                        AIAgentActivity(kind: .toolApproval, title: "Approval needed", detail: "Lima · open_lima_settings", requiresApproval: true)
                    ]
                )
            ]
        )
    }

    private static var failureConversation: AIConversation {
        AIConversation(
            title: "Invalid reasoning request",
            updatedAt: Date(),
            model: "gpt-5.4",
            messages: [
                AIChatMessage(role: .user, text: "Reply with exactly: Lima works"),
                AIChatMessage(
                    role: .assistant,
                    text: "⚠️ Couldn’t complete this response\n\nThe provider rejected the request. Invalid reasoning effort: minimal\n\nRetry after selecting a supported reasoning level.",
                    activities: [
                        AIAgentActivity(kind: .error, title: "Request failed", detail: "Invalid reasoning effort: minimal", completed: true)
                    ]
                )
            ]
        )
    }

    private static var earlierConversation: AIConversation {
        AIConversation(
            title: "MCP request design",
            updatedAt: fixtureNow.addingTimeInterval(-86_400),
            model: "gpt-5.4",
            messages: [AIChatMessage(role: .user, text: "How should remote MCP authorization be sent?")]
        )
    }

    private static var manyConversations: [AIConversation] {
        (1...30).map { index in
            AIConversation(
                title: "Regression scenario \(index) — \(index == 17 ? "A deliberately long chat title that verifies truncation in the sidebar" : "AI workspace")",
                updatedAt: index.isMultiple(of: 3) ? fixtureNow.addingTimeInterval(-86_400) : Date(),
                model: "gpt-5.4",
                messages: [AIChatMessage(role: .user, text: "Fixture preview \(index)")]
            )
        }
    }

    private static var completedActivities: [AIAgentActivity] {
        [
            AIAgentActivity(kind: .started, title: "Started", detail: "Responses stream", startedAt: fixtureNow.addingTimeInterval(-7), endedAt: fixtureNow.addingTimeInterval(-7), completed: true),
            AIAgentActivity(kind: .reasoningSummary, title: "Reasoning", detail: "Checked the capability profile", startedAt: fixtureNow.addingTimeInterval(-6), endedAt: fixtureNow.addingTimeInterval(-3), completed: true),
            AIAgentActivity(kind: .toolCompleted, title: "Search Files", detail: "Lima", startedAt: fixtureNow.addingTimeInterval(-2), endedAt: fixtureNow, usage: AIUsageMetrics(inputTokens: 42, outputTokens: 18), completed: true)
        ]
    }

    private static var fixtureNow: Date {
        Date(timeIntervalSinceReferenceDate: 780_000_000)
    }

    private static func fixtureMCPServer() -> MCPServer {
        let id = UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!
        let tool = MCPToolDescriptor(serverID: id, name: "search_docs", title: "Search documentation", description: "Fixture MCP search", risk: .read, enabled: true)
        return MCPServer(id: id, name: "Fixture Docs", url: "https://example.invalid/mcp", allowedToolNames: [tool.name], tools: [tool])
    }
}
#endif
