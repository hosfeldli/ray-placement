import Foundation
import Testing
@testable import RayPlacementCore

@Test func interfaceScaleIsBoundedAndRestoresSafely() {
    #expect(InterfaceTextScale.normalized(0) == 1)
    #expect(InterfaceTextScale.normalized(.nan) == 1)
    #expect(InterfaceTextScale.normalized(.infinity) == 1)
    #expect(InterfaceTextScale.normalized(0.2) == 0.85)
    #expect(InterfaceTextScale.normalized(3) == 1.4)
    #expect(InterfaceTextScale.normalized(1.23) == 1.25)
    for step in 17...28 {
        let scale = Double(step) / 20
        #expect(InterfaceTextScale.normalized(scale) == scale)
    }
}

@Test func terminalAssistanceCannotInjectReturnOrEscapeSequences() {
    #expect(TerminalWorkspaceInput.isSafeSingleLine("git status && pwd"))
    #expect(!TerminalWorkspaceInput.isSafeSingleLine("pwd\nwhoami"))
    #expect(!TerminalWorkspaceInput.isSafeSingleLine("pwd\r"))
    #expect(!TerminalWorkspaceInput.isSafeSingleLine("\u{1b}[200~exit"))
    #expect(!TerminalWorkspaceInput.isSafeSingleLine("\u{03}"))
    #expect(TerminalWorkspaceInput.shellQuote("/tmp/Liam's project") == "'/tmp/Liam'\\''s project'")
    #expect(TerminalWorkspaceInput.normalizedRemotePath("") == "~")
    #expect(TerminalWorkspaceInput.normalizedRemotePath(" project/one ") == "~/project/one")
    #expect(TerminalWorkspaceInput.normalizedRemotePath("~/project") == "~/project")
    #expect(TerminalWorkspaceInput.normalizedRemotePath("/var/log") == "/var/log")
}

@Test func terminalDirectoryUsesLocalFileURLsWithoutCorruptingLiteralPaths() {
    #expect(TerminalWorkspaceInput.localDirectory("file:///tmp/Project%20One") == "/tmp/Project One")
    #expect(TerminalWorkspaceInput.localDirectory("/tmp/100%20literal") == "/tmp/100%20literal")
    #expect(TerminalWorkspaceInput.localDirectory("file://localhost/tmp/project") == "/tmp/project")
    #expect(TerminalWorkspaceInput.localDirectory("https://example.com/file") == nil)
    #expect(TerminalWorkspaceInput.localDirectory("file://remote-host/tmp/project") == nil)
    #expect(TerminalWorkspaceInput.localDirectory("relative/path") == nil)
}

@Test func terminalRecognizesRemoteDirectoriesAndSafeSSHDestinations() {
    #expect(TerminalWorkspaceInput.remoteDirectory("file://build-vm/home/liam/Project") == .init(host: "build-vm", path: "/home/liam/Project"))
    #expect(TerminalWorkspaceInput.remoteDirectory("file:///tmp/local") == nil)
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh build-vm") == "build-vm")
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -p 2222 liam@build-vm") == "liam@build-vm")
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -J jump liam@build-vm") == "liam@build-vm")
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -p 2222 liam@build-vm") == ["-p", "2222", "--", "liam@build-vm"])
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -J jump -i ~/.ssh/id_ed25519 build-vm") == ["-J", "jump", "-i", "~/.ssh/id_ed25519", "--", "build-vm"])
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -o IdentitiesOnly=yes build-vm") == ["-o", "IdentitiesOnly=yes", "--", "build-vm"])
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -p 0 build-vm") == nil)
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -o ProxyCommand=bad build-vm") == nil)
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -o ProxyCommand=bad host;rm") == nil)
    #expect(TerminalWorkspaceInput.sshDestination(from: "printf ssh") == nil)
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -tt vm-alias") == "vm-alias")
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -p2222 'liam@build-vm'") == "liam@build-vm")
    #expect(TerminalWorkspaceInput.sshDestination(from: "env TERM=xterm command ssh -i ~/.ssh/vm_key vm-alias") == "vm-alias")
    #expect(TerminalWorkspaceInput.sshDestination(from: "sudo -n ssh -tt vm-alias") == "vm-alias")
    #expect(TerminalWorkspaceInput.sshDestination(from: "ssh -vvv -X -o ProxyCommand=helper vm-alias") == "vm-alias")
    #expect(TerminalWorkspaceInput.sshDestination(from: "/usr/bin/ssh -i ~/.ssh/vm_key liam@build-vm") == "liam@build-vm")
    #expect(TerminalWorkspaceInput.sshProcessArguments(from: "ssh -tt -p2222 vm-alias") == ["-p", "2222", "--", "vm-alias"])
    #expect(TerminalWorkspaceInput.remotePath("file:///home/liam/project") == "/home/liam/project")
    #expect(TerminalWorkspaceInput.remoteDirectory("file://localhost/home/liam/project") == nil)
    #expect(TerminalWorkspaceInput.remoteDirectory("file://localhost/home/liam/project", allowLocalHost: true) == .init(host: "localhost", path: "/home/liam/project"))
    #expect(TerminalWorkspaceInput.primaryCommand(in: "  git status") == "git")
}
