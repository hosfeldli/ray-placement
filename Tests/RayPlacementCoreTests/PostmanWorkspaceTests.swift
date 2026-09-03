import Foundation
import Testing
@testable import RayPlacementCore

@Suite struct PostmanWorkspaceTests {
    @Test func importsNestedCollectionAndInheritedBearerAuthentication() throws {
        let json = #"""
        {
          "info": { "name": "Workspace", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "auth": { "type": "bearer", "bearer": [{ "key": "token", "value": "{{token}}" }] },
          "variable": [{ "key": "base", "value": "https://example.com" }],
          "item": [{
            "name": "Users",
            "item": [{
              "name": "Create user",
              "request": {
                "method": "POST",
                "header": [{ "key": "X-Client", "value": "RayPlacement" }],
                "body": { "mode": "raw", "raw": "{\"name\":\"Liam\"}", "options": { "raw": { "language": "json" } } },
                "url": { "raw": "{{base}}/users", "query": [{ "key": "active", "value": "true" }] }
              }
            }]
          }]
        }
        """#.data(using: .utf8)!

        guard case .collection(let collection) = try PostmanImporter.decode(json) else {
            Issue.record("Expected collection")
            return
        }
        #expect(collection.name == "Workspace")
        #expect(collection.variables["base"] == "https://example.com")
        #expect(collection.requests.count == 1)
        #expect(collection.requests[0].folderPath == ["Users"])
        #expect(collection.requests[0].authorization.kind == .bearer)
        #expect(collection.requests[0].authorization.values["token"] == "{{token}}")
        #expect(collection.requests[0].contentType == "application/json")
    }

    @Test func importsEnvironmentAndResolvesVariables() throws {
        let json = #"""
        { "name": "Local", "values": [
          { "key": "host", "value": "localhost:8080", "enabled": true },
          { "key": "disabled", "value": "ignored", "enabled": false }
        ] }
        """#.data(using: .utf8)!

        guard case .environment(let environment) = try PostmanImporter.decode(json) else {
            Issue.record("Expected environment")
            return
        }
        #expect(environment.resolvedValues == ["host": "localhost:8080"])
        #expect(PostmanVariableResolver.resolve("http://{{ host }}/v1/{{missing}}", values: environment.resolvedValues) == "http://localhost:8080/v1/{{missing}}")
    }

    @Test func importsQueryAPIKeyAndDisabledRequestRows() throws {
        let json = #"""
        {
          "info": { "name": "Authenticated", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "item": [{
            "name": "Lookup",
            "request": {
              "method": "GET",
              "auth": { "type": "apikey", "apikey": [
                { "key": "key", "value": "api_key" },
                { "key": "value", "value": "{{secret}}" },
                { "key": "in", "value": "query" }
              ] },
              "url": { "raw": "https://example.com/lookup", "query": [
                { "key": "active", "value": "true" },
                { "key": "debug", "value": "true", "disabled": true }
              ] }
            }
          }]
        }
        """#.data(using: .utf8)!

        guard case .collection(let collection) = try PostmanImporter.decode(json) else {
            Issue.record("Expected collection")
            return
        }
        let request = try #require(collection.requests.first)
        #expect(request.authorization.kind == .apiKey)
        #expect(request.authorization.values["in"] == "query")
        #expect(request.authorization.values["value"] == "{{secret}}")
        #expect(request.parameters.map(\.enabled) == [true, false])
    }
}

extension PostmanWorkspaceTests {
    @Test func importsScriptsFormDataAndOAuth() throws {
        let json = #"""
        {
          "info": { "name": "Scripts", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "event": [
            { "listen": "prerequest", "script": { "exec": ["pm.environment.set('token', 'abc');"] } },
            { "listen": "test", "script": { "exec": ["pm.test('status', function () { pm.response.to.have.status(200); });"] } }
          ],
          "item": [{
            "name": "Form",
            "request": {
              "method": "POST",
              "auth": { "type": "oauth2", "oauth2": [{ "key": "accessToken", "value": "{{token}}" }] },
              "body": { "mode": "formdata", "formdata": [{ "key": "name", "value": "Liam" }] },
              "url": "https://example.com/form"
            }
          }]
        }
        """#.data(using: .utf8)!

        guard case .collection(let collection) = try PostmanImporter.decode(json) else {
            Issue.record("Expected collection")
            return
        }
        let request = try #require(collection.requests.first)
        #expect(request.authorization.kind == .oauth2)
        #expect(request.bodyMode == "formdata")
        #expect(request.bodyFields?.first?.key == "name")
        #expect(collection.preRequestScript?.contains("pm.environment.set") == true)
        #expect(request.testScript?.contains("pm.test") == true)
    }

    @Test func runsPreRequestVariablesAndEvaluatesAssertions() {
        var variables = ["base": "https://example.com"]
        PostmanScriptInterpreter.apply("pm.environment.set('token', 'abc');", to: &variables)
        #expect(variables["token"] == "abc")
        #expect(PostmanVariableResolver.resolve("{{base}}/{{token}}", values: variables) == "https://example.com/abc")

        let response = PostmanResponseSnapshot(statusCode: 201, body: #"{"id":"123"}"#)
        let results = PostmanTestEvaluator.evaluate("pm.test('created', function () { pm.response.to.have.status(201); });", response: response)
        #expect(results.count == 1)
        #expect(results.first?.passed == true)
    }

    @Test func parsesJSONAndCSVRunnerData() throws {
        let jsonRows = try PostmanDataFileParser.parse(Data(#"[{"id":1},{"id":2}]"#.utf8), fileExtension: "json")
        #expect(jsonRows.map { $0["id"] ?? "" } == ["1", "2"])
        let csvRows = try PostmanDataFileParser.parse(Data("id,name\n1,\"Liam, Jr.\"\n2,Ada\n".utf8), fileExtension: "csv")
        #expect(csvRows[0]["name"] == "Liam, Jr.")
        #expect(csvRows[1]["id"] == "2")
    }
}
