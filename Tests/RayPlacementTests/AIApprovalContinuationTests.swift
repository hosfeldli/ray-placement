import Foundation
import Testing
@testable import RayPlacement

@Test func approvalContinuationSnapshotKeepsTheExactTurnRoutingBundle() {
    let localTool = LimaAIToolDefinition(
        id: "browser_click",
        name: "browser_click",
        description: "Click a semantic Browser control.",
        parameters: [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String],
            "additionalProperties": false
        ],
        risk: .localAction
    )
    let instructions = "Captured capability and approval instructions."

    let snapshot = AIApprovalContinuationContext(
        localTools: [localTool],
        systemInstructions: instructions
    )

    #expect(snapshot.localToolIDs == ["browser_click"])
    #expect(snapshot.systemInstructions == instructions)
}
