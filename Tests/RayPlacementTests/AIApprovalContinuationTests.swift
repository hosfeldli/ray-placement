import Foundation
import Testing
@testable import RayPlacement

@Test func approvalContinuationSnapshotKeepsTheExactTurnRoutingBundle() {
    let localTool = LimaAIToolDefinition(
        id: "browser_click",
        name: "browser_click",
        description: "Click a granted browser control.",
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
            "additionalProperties": false
        ],
        risk: .localAction
    )
    let server = MCPServer(
        name: "Docs",
        url: "https://mcp.example.test",
        allowedToolNames: ["search"]
    )
    let browser = BrowserCapabilityTurnContext(
        selectedAgentID: "browser-agent",
        selectedAgentToolIDs: ["browser_read", "browser_click"],
        enabledToolIDs: ["browser_read", "browser_click"],
        turnToolIDs: ["browser_read", "browser_click"],
        pendingApproval: true
    )
    let instructions = "Captured capability and approval instructions."

    let snapshot = AIApprovalContinuationContext(
        localTools: [localTool],
        mcpServers: [server],
        browserRoutingContext: browser,
        systemInstructions: instructions
    )

    #expect(snapshot.localToolIDs == ["browser_click"])
    #expect(snapshot.mcpServerIDs == [server.id])
    #expect(snapshot.browserRoutingContext == browser)
    #expect(snapshot.systemInstructions == instructions)
}
