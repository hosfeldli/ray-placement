import Foundation
import LimaQAProtocol
import Testing

@Test func runtimeAuthorizationRequiresBothIndependentOptIns() {
    #expect(!LimaQAAuthorization.isAuthorized(environment: [:]))
    #expect(!LimaQAAuthorization.isAuthorized(environment: ["LIMA_TEST_MODE": "1"]))
    #expect(!LimaQAAuthorization.isAuthorized(environment: ["LIMA_ENABLE_QA_MCP": "1"]))
    #expect(!LimaQAAuthorization.isAuthorized(environment: [
        "LIMA_TEST_MODE": "true",
        "LIMA_ENABLE_QA_MCP": "1"
    ]))
    #expect(LimaQAAuthorization.isAuthorized(environment: [
        "LIMA_TEST_MODE": "1",
        "LIMA_ENABLE_QA_MCP": "1"
    ]))
}

@Test func QAServiceStartsOnlyWhenSettingsAndBothRuntimeOptInsAllowIt() {
    let authorized = ["LIMA_TEST_MODE": "1", "LIMA_ENABLE_QA_MCP": "1"]
    #expect(!LimaQAAuthorization.shouldStartAtLaunch(environment: authorized, userEnabled: false))
    #expect(!LimaQAAuthorization.shouldStartAtLaunch(environment: ["LIMA_TEST_MODE": "1"], userEnabled: true))
    #expect(LimaQAAuthorization.shouldStartAtLaunch(environment: authorized, userEnabled: true))
}

@Test func internalProtocolRoundTripsBoundedRequestsAndResponses() throws {
    let request = LimaQARequest(
        id: "request-1",
        method: "surface.open",
        params: ["surface": "notes"]
    )
    let requestData = try LimaQAWire.encodeRequest(request)
    #expect(requestData.last == 10)
    #expect(try LimaQAWire.decodeRequest(requestData) == request)

    let response = LimaQAResponse(
        id: "request-1",
        ok: true,
        payload: #"{"opened":"notes"}"#
    )
    let responseData = try LimaQAWire.encodeResponse(response)
    #expect(try LimaQAWire.decodeResponse(responseData) == response)
}

@Test func internalProtocolRejectsOversizedMessages() {
    let oversized = Data(repeating: 65, count: LimaQAWire.maximumMessageBytes + 1)
    #expect(throws: LimaQAWireError.messageTooLarge) {
        try LimaQAWire.decodeRequest(oversized)
    }
    let largeParams = Dictionary(uniqueKeysWithValues: (0..<32).map {
        (String($0), String(repeating: "x", count: 16_000))
    })
    #expect(throws: LimaQAWireError.messageTooLarge) {
        try LimaQAWire.encodeRequest(LimaQARequest(
            id: "large",
            method: "ui.setText",
            params: largeParams
        ))
    }
}

@Test func unixSocketPathIsPerUserAndNotATcpEndpoint() {
    let path = LimaQASocketClient.defaultSocketPath
    #expect(path.hasPrefix("/tmp/limaqa-"))
    #expect(path.hasSuffix(".sock"))
    #expect(!path.contains(":"))
}
