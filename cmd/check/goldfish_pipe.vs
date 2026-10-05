import (
    "vm/android"
    "vm/device"
    "vm/goldfish"
)

/// A guest driver for the pipe, as goldfish_pipe_v2.c drives it: a
/// device page for the open parameters and signal list, and a command
/// page per pipe.
final class PipeDriver {
    let dev: goldfish.Pipe
    let mem: device.GuestMemory
    let devPage: uint64        // open_command_params at +0, signalled_pipe_buffers at +16
    var nextPage: uint64
    var pages: [uint32: uint64] = [:]

    init(_ dev: goldfish.Pipe, _ mem: device.GuestMemory, base: uint64) {
        self.dev = dev
        self.mem = mem
        devPage = base
        nextPage = base + 0x1000
        dev.Write(offset: 36, size: 4, value: 4)   // the driver's version
        _ = dev.Read(offset: 36, size: 4)
        dev.Write(offset: 4, size: 4, value: (devPage + 16) >> 32)
        dev.Write(offset: 8, size: 4, value: (devPage + 16) & 0xffff_ffff)
        dev.Write(offset: 12, size: 4, value: 64)
        dev.Write(offset: 20, size: 4, value: devPage >> 32)
        dev.Write(offset: 24, size: 4, value: devPage & 0xffff_ffff)
    }

    func status(_ id: uint32) -> int32 { int32(bitPattern: try! mem.Load32(device.GuestAddress(pages[id]! + 8))) }

    func cmd(_ id: uint32, _ c: int32) -> int32 {
        let page = device.GuestAddress(pages[id]!)
        try! mem.Store32(page, uint32(bitPattern: c))
        try! mem.Store32(page.Adding(8), uint32(bitPattern: -1))
        dev.Write(offset: 0, size: 4, value: uint64(id))
        return status(id)
    }

    func open(_ id: uint32) -> int32 {
        let page = nextPage
        nextPage += 0x1000
        pages[id] = page
        try! mem.Store32(device.GuestAddress(page + 4), id)
        try! mem.Store64(device.GuestAddress(devPage), page)
        try! mem.Store32(device.GuestAddress(devPage + 8), 336)
        return cmd(id, 1)
    }

    /// A read or write through one buffer at `at`; the status.
    func rw(_ id: uint32, write: bool, at: uint64, count: int) -> int32 {
        let page = device.GuestAddress(pages[id]!)
        try! mem.Store32(page.Adding(16), 1)
        try! mem.Store64(page.Adding(24), at)
        try! mem.Store32(page.Adding(24 + 336 * 8), uint32(count))
        return cmd(id, write ? 4 : 6)
    }

    func write(_ id: uint32, _ bytes: [uint8]) -> int32 {
        let at = nextPage
        try! mem.Write(device.GuestAddress(at), bytes)
        return rw(id, write: true, at: at, count: bytes.count)
    }

    func read(_ id: uint32, max: int) -> [uint8]? {
        let at = nextPage
        let n = rw(id, write: false, at: at, count: max)
        if n <= 0 { return nil }
        return try! mem.Read(device.GuestAddress(at), count: int(n))
    }

    /// GET_SIGNALLED, and the (id, flags) entries it wrote.
    func signalled() -> [(uint32, uint32)] {
        let n = int(dev.Read(offset: 48, size: 4))
        var out: [(uint32, uint32)] = []
        for i in 0..<n {
            let at = device.GuestAddress(devPage + 16 + uint64(i) * 8)
            out.append((try! mem.Load32(at), try! mem.Load32(at.Adding(4))))
        }
        return out
    }
}

/// A qemud service that echoes each message back, in capitals.
final class ShoutService: goldfish.QemudService {
    var clients: [goldfish.QemudClient] = []
    func Received(_ message: [uint8], from client: goldfish.QemudClient) {
        clients.append(client)
        client.Reply(bytes: message.map { $0 >= 0x61 && $0 <= 0x7a ? $0 - 32 : $0 })
    }
}

/// vm/goldfish's pipe, driven as goldfish_pipe_v2.c drives it, and the
/// qemud framing and boot-properties service on top of it.
func checkGoldfishPipe() {
    let mem = try! scratchMemory(base: 0x4000_0000, size: 1 << 20)
    let irq = device.RecordingIrq()
    let pipe = goldfish.Pipe(memory: mem.0, irq: irq)
    let shout = ShoutService()
    pipe.Register("qemud:shout", goldfish.QemudPipe(shout))
    pipe.Register("qemud:boot-properties", goldfish.QemudPipe(android.BootPropertiesService(android.BootProperties.ForScreen(width: 720))))
    let d = PipeDriver(pipe, mem.0, base: 0x4000_0000)

    check(d.dev.Read(offset: 36, size: 4) == 2, "goldfish-pipe: device version 2")
    check(d.open(3) == 0 && pipe.OpenCount == 1, "goldfish-pipe: PIPE_CMD_OPEN through the open buffer")

    // The connect string can arrive in pieces; only bytes up to the NUL are taken.
    check(d.write(3, Array("pipe:qemud:sh".utf8)) == 13, "goldfish-pipe: a partial service name is taken")
    var rest = Array("out".utf8)
    rest.append(0)
    rest += Array("0005hello".utf8)
    check(d.write(3, rest) == 4, "goldfish-pipe: the name ends at its NUL, the rest is left")
    check(d.read(3, max: 16) == nil && d.status(3) == -2, "goldfish-pipe: nothing to read yet is PIPE_ERROR_AGAIN")

    // Ask to be woken; the message makes the reply readable and signals.
    check(d.cmd(3, 7) == 0 && !irq.Level, "goldfish-pipe: WAKE_ON_READ with nothing to read waits")
    check(d.write(3, Array("0005hello".utf8)) == 9, "goldfish-pipe: a qemud frame is taken whole")
    check(irq.Level, "goldfish-pipe: the reply raises the interrupt")
    let sig = d.signalled()
    check(sig.count == 1 && sig[0].0 == 3 && sig[0].1 == 2 && !irq.Level, "goldfish-pipe: GET_SIGNALLED lists pipe 3, PIPE_WAKE_READ, and lowers the line (\(sig))")
    let got = d.read(3, max: 64).map { string(decoding: $0, as: UTF8.self) }
    check(got == "0005HELLO", "goldfish-pipe: the reply is framed (\(got ?? "nil"))")

    // A wake asked for after the data arrived is signalled at once.
    _ = d.write(3, Array("0002ok".utf8))
    check(!irq.Level, "goldfish-pipe: no wake for a pipe that didn't ask")
    _ = d.cmd(3, 7)
    check(irq.Level && d.signalled().count == 1, "goldfish-pipe: WAKE_ON_READ with data waiting signals at once")
    _ = d.read(3, max: 64)

    // POLL: writable always; readable when a reply waits.
    check(d.cmd(3, 3) == 2, "goldfish-pipe: POLL is PIPE_POLL_OUT when idle")

    // Unknown services are refused and remembered.
    _ = d.open(4)
    var bad = Array("pipe:nosuch".utf8)
    bad.append(0)
    check(d.write(4, bad) == -1 && pipe.Refused == ["pipe:nosuch"], "goldfish-pipe: an unknown service is PIPE_ERROR_INVAL, and noted")

    // boot-properties: "list", then a property per message, then a lone NUL.
    _ = d.open(5)
    var name = Array("pipe:qemud:boot-properties".utf8)
    name.append(0)
    _ = d.write(5, name)
    _ = d.write(5, Array("0004list".utf8))
    var props: [string] = []
    var ended = false
    var buf = d.read(5, max: 4096) ?? []
    while buf.count >= 4 {
        let n = int(string(decoding: buf[0..<4], as: UTF8.self), radix: 16) ?? 0
        let body = Array(buf[4..<4 + n])
        buf.removeFirst(4 + n)
        if body == [0] { ended = true; break }
        props.append(string(decoding: body, as: UTF8.self))
    }
    check(ended && props == ["qemu.hw.mainkeys=0"],
          "goldfish-pipe: boot-properties sends what isn't read at startup, then ends (\(props))")

    // logcat: lines of text, taken whole or in pieces.
    let logcat = android.LogcatService()
    var lines: [string] = []
    logcat.OnLine = { lines.append($0) }
    pipe.Register("logcat", logcat)
    _ = d.open(6)
    var lc = Array("pipe:logcat".utf8)
    lc.append(0)
    check(d.write(6, lc) == 12, "goldfish-pipe: logcat connects")
    _ = d.write(6, Array("I/one: a\nW/tw".utf8))
    _ = d.write(6, Array("o: b\n".utf8))
    check(lines == ["I/one: a", "W/two: b"], "goldfish-pipe: logcat lines arrive whole (\(lines))")

    // CLOSE frees the id; reading the version (a reboot) closes everything.
    check(d.cmd(3, 2) == 0 && pipe.OpenCount == 3, "goldfish-pipe: CLOSE")
    _ = d.dev.Read(offset: 36, size: 4)
    check(pipe.OpenCount == 0, "goldfish-pipe: a driver probe closes the old pipes")
}
