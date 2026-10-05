// Package tpm is a TPM 2.0 for guests: a TIS register interface (`Tis`,
// TCG PC Client Platform TPM Profile, FIFO interface) that firmware and
// operating systems drive with their own drivers, in front of a `Backend`
// that executes TPM 2.0 commands.
//
// The one backend today is `Swtpm`: the swtpm process (libtpms), which is
// what QEMU uses. A backend of Vertex's own can replace it behind the same
// protocol.
package tpm

import (
    "encoding/binary"
    "fs"
    "net/unix"
    "os/process"
    "time"
)

/// Executes TPM 2.0 commands. `Tis` calls one method at a time.
public protocol Backend: AnyObject {
    /// Powers the TPM on, or resets it: each time the machine starts.
    func Init() async throws
    /// One command, in and out as the TPM 2.0 wire format has them, sent
    /// at `locality`.
    func Execute(_ command: [uint8], locality: uint8) async throws -> [uint8]
    /// Stops the TPM, saving its state.
    func Shutdown()
}

public enum TpmError: Error, CustomStringConvertible {
    case backendMissing(string)
    case backendFailed(string)

    public var description: string {
        switch self {
        case .backendMissing(let what): return "TPM backend not found: \(what)"
        case .backendFailed(let what): return "TPM backend failed: \(what)"
        }
    }
}

/// A response saying the TPM failed (TPM_RC_FAILURE): what the guest gets
/// when the backend can't be reached, rather than a TPM that never answers.
public func FailureResponse() -> [uint8] {
    [0x80, 0x01, 0, 0, 0, 10, 0, 0, 0x01, 0x01]
}

/// The size field of a TPM 2.0 command or response header.
func wireSize(_ b: [uint8]) -> int {
    b.count < 6 ? 0 : int(binary.BigEndian.Uint32(b, from: 2))
}

/// swtpm, the TPM 2.0 emulator over libtpms, as a child process: its data
/// channel takes commands, its control channel powers it on and sets the
/// locality (swtpm's ioctl protocol, `tpm_ioctl.h`). Both are Unix sockets
/// in a directory only this user can open; swtpm exits when the control
/// connection goes, so it never outlives the VM.
///
/// The TPM's state -- its seeds, NV, the EK Windows makes -- persists in
/// `StateDir`, so a guest sees the same TPM every boot.
public final class Swtpm: Backend {
    public let StateDir: string
    public let Executable: string
    var child: process.Child? = nil
    var socketDir: fs.Path? = nil
    var control: unix.UnixStream? = nil
    var data: unix.UnixStream? = nil
    var locality: uint8 = 0

    // Control commands (tpm_ioctl.h): a big-endian number, its request,
    // and a big-endian result first in every response.
    static let cmdInit: uint32 = 0x02
    static let cmdShutdown: uint32 = 0x03
    static let cmdSetLocality: uint32 = 0x05

    public init(stateDir: string, executable: string = "swtpm") {
        StateDir = stateDir
        Executable = executable
    }

    /// Whether swtpm can be found on PATH (or at `Executable`).
    public static func Available(_ executable: string = "swtpm") -> bool {
        process.Find(executable) != nil
    }

    public func Init() async throws {
        if child == nil {
            try await start()
        }
        // INIT with no flags: power on, keeping the permanent state.
        var req = [uint8](repeating: 0, count: 4)
        binary.BigEndian.PutUint32(&req, 0, at: 0)
        try await controlCommand(Swtpm.cmdInit, req)
        locality = 0
    }

    func start() async throws {
        guard process.Find(Executable) != nil else {
            throw TpmError.backendMissing("\(Executable) is not on PATH (brew install swtpm)")
        }
        try fs.CreateDir(fs.Path(StateDir), all: true)
        let dir = try fs.TempDir(prefix: "vertex-tpm-")
        socketDir = dir
        let dataPath = dir.Value + "/data"
        let controlPath = dir.Value + "/ctrl"
        var cmd = process.Command(Executable, [
            "socket", "--tpm2",
            "--tpmstate", "dir=\(StateDir),mode=0600",
            "--server", "type=unixio,path=\(dataPath),mode=0600",
            "--ctrl", "type=unixio,path=\(controlPath),mode=0600,terminate",
            "--log", "file=\(StateDir)/swtpm.log,level=1",
        ])
        cmd.Stdin = .null
        cmd.Stdout = .null
        cmd.Stderr = .file(StateDir + "/swtpm.stderr")
        child = try cmd.Spawn()

        // swtpm makes its sockets once it is up.
        var lastError: (any Error)? = nil
        for _ in 0..<100 {
            do {
                control = try await unix.Connect(controlPath)
                data = try await unix.Connect(dataPath)
                return
            } catch {
                lastError = error
                if let c = child, let status = try? c.TryWait() {
                    throw TpmError.backendFailed("swtpm exited (\(status)); see \(StateDir)/swtpm.stderr")
                }
                try? await time.Sleep(.Milliseconds(30))
            }
        }
        throw TpmError.backendFailed("swtpm's sockets never came up: \(lastError.map { "\($0)" } ?? "")")
    }

    func controlCommand(_ code: uint32, _ request: [uint8]) async throws {
        guard let c = control else { throw TpmError.backendFailed("not started") }
        var msg = [uint8](repeating: 0, count: 4)
        binary.BigEndian.PutUint32(&msg, code, at: 0)
        msg.append(contentsOf: request)
        try await c.Write(msg)
        var result = [uint8](repeating: 0, count: 4)
        try await c.ReadFull(into: &result)
        let rc = binary.BigEndian.Uint32(result, from: 0)
        if rc != 0 {
            throw TpmError.backendFailed("control command \(code) answered 0x\(string(rc, radix: 16))")
        }
    }

    public func Execute(_ command: [uint8], locality l: uint8) async throws -> [uint8] {
        if child == nil {
            try await Init()
        }
        if l != locality {
            try await controlCommand(Swtpm.cmdSetLocality, [l])
            locality = l
        }
        guard let d = data else { throw TpmError.backendFailed("not started") }
        try await d.Write(command)
        var header = [uint8](repeating: 0, count: 10)
        try await d.ReadFull(into: &header)
        let size = wireSize(header)
        if size < 10 || size > 64 * 1024 {
            throw TpmError.backendFailed("a response of \(size) bytes")
        }
        var rest = [uint8](repeating: 0, count: size - 10)
        if !rest.isEmpty {
            try await d.ReadFull(into: &rest)
        }
        return header + rest
    }

    public func Shutdown() {
        // Closing the control channel makes swtpm save and exit
        // (`terminate`); the socket directory goes with it.
        if let d = data { d.Close() }
        if let c = control { c.Close() }
        data = nil
        control = nil
        if let ch = child {
            Task {
                _ = try? await ch.Wait()
            }
        }
        child = nil
        if let dir = socketDir {
            try? fs.RemoveAll(dir)
        }
        socketDir = nil
    }

    deinit {
        Shutdown()
    }
}
