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
