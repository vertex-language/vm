import (
    "encoding/binary"
    "fs"
    "vm/tpm"
    "vm/windows"
)

/// A backend that answers every command with its own bytes reversed,
/// wrapped in a response header: enough to see the FIFO carry both ways.
final class EchoBackend: tpm.Backend {
    var commands: [[uint8]] = []
    var localities: [uint8] = []
    func Init() async throws {}
    func Execute(_ command: [uint8], locality: uint8) async throws -> [uint8] {
        commands.append(command)
        localities.append(locality)
        var r: [uint8] = [0x80, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
        r.append(contentsOf: command.reversed())
        binary.BigEndian.PutUint32(&r, uint32(r.count), at: 2)
        return r
    }
    func Shutdown() {}
}

/// Runs one command through the TIS registers at locality 0, as a driver
/// does, and is the response (nil on a protocol failure).
func tisCommand(_ tis: tpm.Tis, _ command: [uint8]) async -> [uint8]? {
    tis.Write(offset: 0x00, size: 1, value: 0x02)                       // request use
    if tis.Read(offset: 0x00, size: 1) & 0x20 == 0 { return nil }      // active?
    tis.Write(offset: 0x18, size: 1, value: 0x40)                       // command ready
    if tis.Read(offset: 0x18, size: 1) & 0x40 == 0 { return nil }
    for b in command {
        tis.Write(offset: 0x24, size: 1, value: uint64(b))
    }
    if tis.Read(offset: 0x18, size: 1) & 0x08 != 0 { return nil }      // still expecting?
    tis.Write(offset: 0x18, size: 1, value: 0x20)                       // go
    let ready = await settle { tis.Read(offset: 0x18, size: 4) & 0x90 == 0x90 }
    if !ready { return nil }
    var out: [uint8] = []
    for _ in 0..<6 { out.append(uint8(tis.Read(offset: 0x24, size: 1))) }
    let size = int(binary.BigEndian.Uint32(out, from: 2))
    while out.count < size {
        let v = tis.Read(offset: 0x24, size: 4)
        for i in 0..<min(4, size - out.count) { out.append(uint8((v >> (8 * uint64(i))) & 0xff)) }
    }
    let done = tis.Read(offset: 0x18, size: 1) & 0x10 == 0
    tis.Write(offset: 0x18, size: 1, value: 0x40)                       // back to ready
    tis.Write(offset: 0x00, size: 1, value: 0x20)                       // give up the locality
    return done ? out : nil
}

func checkTpm() async {
    let echo = EchoBackend()
    let tis = tpm.Tis(backend: echo)
    check(tis.Read(offset: 0xf00, size: 4) == 0x0001_1014, "TPM: TIS DID/VID")
    check(tis.Read(offset: 0x00, size: 1) & 0xa0 == 0x80, "TPM: no locality is active at first")
    check(tis.Read(offset: 0x18, size: 4) == 0xffff_ffff, "TPM: status reads all ones for an inactive locality")
    tis.Write(offset: 0x00, size: 1, value: 0x02)
    check(tis.Read(offset: 0x18, size: 4) >> 26 & 3 == 1, "TPM: TIS reports the TPM 2.0 family")
    tis.Write(offset: 0x00, size: 1, value: 0x20)
    let command: [uint8] = [0x80, 0x01, 0, 0, 0, 14, 0, 0, 0x01, 0x7b, 0xaa, 0xbb, 0xcc, 0xdd]
    if let r = await tisCommand(tis, command) {
        check(echo.commands.count == 1 && echo.commands[0] == command && echo.localities[0] == 0,
              "TPM: the command reaches the backend whole, at locality 0")
        check(r.count == 24 && Array(r[10..<24]) == Array(command.reversed()), "TPM: the response reads back out of the FIFO")
    } else {
        check(false, "TPM: a command round trip through the TIS")
    }
    check(tis.Read(offset: 0x00, size: 1) & 0x20 == 0, "TPM: giving up the locality leaves none active")

    // The real thing, where swtpm is installed: Startup, then 8 random bytes.
    if !tpm.Swtpm.Available() {
        print("skip  TPM: swtpm is not installed")
        return
    }
    guard let dir = try? fs.TempDir(prefix: "vertex-tpm-check-") else { return }
    defer { try? fs.RemoveAll(dir) }
    let real = tpm.Tis(backend: tpm.Swtpm(stateDir: dir.Value + "/state"))
    defer { real.Shutdown() }
    let startup: [uint8] = [0x80, 0x01, 0, 0, 0, 12, 0, 0, 0x01, 0x44, 0, 0]
    let s = await tisCommand(real, startup)
    check(s != nil && s!.count == 10 && binary.BigEndian.Uint32(s!, from: 6) == 0, "TPM: swtpm answers TPM2_Startup(CLEAR) with success")
    let random: [uint8] = [0x80, 0x01, 0, 0, 0, 12, 0, 0, 0x01, 0x7b, 0, 8]
    let g = await tisCommand(real, random)
    check(g != nil && g!.count == 20 && binary.BigEndian.Uint32(g!, from: 6) == 0 && g![11] == 8,
          "TPM: swtpm answers TPM2_GetRandom with 8 bytes")
}

/// The bundled firmware (firmware/, run from the repository): Secure Boot
/// code and a variable store with Microsoft's Windows CAs enrolled.
func checkFirmware() {
    guard let fw = try? windows.FindFirmware() else {
        check(false, "Firmware: found")
        return
    }
    check(fw.SecureBoot && fw.Code.count == 64 << 20 && fw.VarsTemplate.count == 64 << 20,
          "Firmware: the bundled Secure Boot firmware and its 64 MiB banks")
    // Certificates are DER: their names are in the store as plain bytes.
    func has(_ text: string) -> bool {
        let n = Array(text.utf8)
        var i = 0
        while i + n.count <= fw.VarsTemplate.count {
            if fw.VarsTemplate[i] == n[0] && Array(fw.VarsTemplate[i..<i + n.count]) == n { return true }
            i += 1
        }
        return false
    }
    check(has("Microsoft Windows Production PCA 2011") && has("Windows UEFI CA 2023"),
          "Firmware: Windows' signing CAs (2011 and 2023) are enrolled in db")
}
