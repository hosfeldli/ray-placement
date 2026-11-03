import Foundation
import Testing
@testable import RayPlacement

@Test func bunInstalledCLIUsesItsRuntimeWithoutShellOrWrapper() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("LimaBun-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("custom bun")
    let bin = root.appendingPathComponent("bin")
    let script = root.appendingPathComponent("install/global/node_modules/example/cli.js")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/usr/bin/env node\nconsole.log('fixture')".utf8).write(to: script)
    let bun = bin.appendingPathComponent("bun")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"".utf8).write(to: bun)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bun.path)
    let cli = bin.appendingPathComponent("opencode")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: script)
    let environment = ["PATH":"/usr/bin:/bin", "BUN_INSTALL":root.path, "FIXTURE":"preserved"]
    #expect(CLILaunchEnvironment.find("opencode", environment: environment, home: home) == cli)
    let args = ["run", "--model", "provider/model", "literal $(touch nope)"]
    let plan = CLILaunchEnvironment.plan(executable: cli, arguments: args, environment: environment, home: home)
    #expect(plan.executable == bun)
    #expect(plan.arguments == ["run", "--bun", script.path] + args)
    #expect(plan.environment["FIXTURE"] == "preserved")
    #expect(plan.environment["PATH"]?.components(separatedBy: ":").contains(bin.path) == true)
    let process = Process()
    process.executableURL = plan.executable
    process.arguments = plan.arguments
    process.environment = plan.environment
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: data, as: UTF8.self).contains("literal $(touch nope)"))
    // Absolute Node shebangs also need the Bun runtime. Shell launchers remain shells.
    try Data("#!/usr/bin/node\n".utf8).write(to: script)
    #expect(CLILaunchEnvironment.plan(executable: cli, arguments: [], environment: environment, home: home).executable == bun)
    try Data("#!/bin/sh node\n".utf8).write(to: script)
    #expect(CLILaunchEnvironment.plan(executable: cli, arguments: args, environment: environment, home: home).executable == cli)
    #expect(CLILaunchEnvironment.find("opencode", environment: environment, home: home, override: "/missing/cli") == nil)
}

@Test func cliDiscoveryIncludesBunGlobalBinsAndPreservesNativeLaunchers() throws {
    let home = URL(fileURLWithPath: "/tmp/fixture-home")
    let environment = ["BUN_INSTALL":"/tmp/custom-bun", "BUN_INSTALL_GLOBAL_BIN":"/tmp/global-bin", "PATH":"relative:/usr/bin:/usr/bin"]
    let dirs = CLILaunchEnvironment.directories(environment: environment, home: home)
    #expect(dirs.contains("/tmp/global-bin"))
    #expect(dirs.contains("/tmp/custom-bun/install/global/node_modules/.bin"))
    #expect(dirs.contains("/tmp/fixture-home/.bun/bin"))
    #expect(!dirs.contains("relative"))
    #expect(dirs.filter { $0 == "/usr/bin" }.count == 1)
    let native = URL(fileURLWithPath: "/usr/bin/true")
    let plan = CLILaunchEnvironment.plan(executable: native, arguments: ["--fixture"], environment: environment, home: home)
    #expect(plan.executable == native)
    #expect(plan.arguments == ["--fixture"])
}
