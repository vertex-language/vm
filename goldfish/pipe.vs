package goldfish

import (
    "sync"
    "vm/device"
)

/// What a pipe operation did, as the guest's driver reads it.
public enum Transfer: Equatable {
    /// `n` bytes moved (more than zero).
    case done(int)
    /// Nothing can move now; the guest waits for a wake (PIPE_ERROR_AGAIN).
    case again
    /// The host side is gone; the guest reads end-of-file.
    case closed
}

/// What the guest may do with a pipe without waiting, as PIPE_CMD_POLL reports it.
public struct PollFlags: Equatable {
    public var Readable: bool
    public var Writable: bool
    public var HungUp: bool

    public init(readable: bool = false, writable: bool = true, hungUp: bool = false) {
        Readable = readable
        Writable = writable
        HungUp = hungUp
    }

    var bits: uint32 {
        (Readable ? 1 : 0) | (Writable ? 2 : 0) | (HungUp ? 4 : 0)
    }
}

/// The host side of one guest connection to a service. Its methods run on
/// the vCPU thread that issued the command, and the guest waits for them:
/// they take or hand over bytes and return; slow work goes to a task,
/// which calls the connection's Waker when the guest can go on.
public protocol PipeConnection: AnyObject {
    /// Takes bytes the guest wrote: some or all of them, or none (`.again`).
    func Send(_ bytes: [uint8]) -> Transfer
    /// Hands the guest at most `max` bytes. An empty array is `.again`
    /// unless the connection is closed.
    func Receive(max: int) -> [uint8]
    /// Whether the connection has finished for good: Receive then
    /// returns end-of-file and Send fails.
    var Closed: bool { get }
    /// Whether Receive would return bytes now.
    var Readable: bool { get }
    /// Whether Send would take bytes now.
    var Writable: bool { get }
    /// The guest closed its end.
    func Close()
}

/// A service a guest opens by writing "pipe:<name>" or
/// "pipe:<name>:<args>" to /dev/qemu_pipe.
public protocol PipeService: AnyObject {
    /// A connection for `args` (empty when there were none), or nil to
    /// refuse it. `waker` tells the guest when a connection that said
    /// `.again` can go on.
    func Open(_ args: string, waker: Waker) -> (any PipeConnection)?
}

/// Lets a connection wake a guest waiting on it.
public final class Waker {
    weak var pipe: Pipe?
    let id: uint32

    init(pipe: Pipe, id: uint32) {
        self.pipe = pipe
        self.id = id
    }

    /// The guest may read again. Cheap when it isn't waiting.
    public func Readable() { pipe?.signal(id, Pipe.wakeRead) }
    /// The guest may write again.
    public func Writable() { pipe?.signal(id, Pipe.wakeWrite) }
    /// The host closed the connection.
    public func Closed() { pipe?.signal(id, Pipe.wakeClosed) }
}

/// The Android emulator's pipe device ("generic,android-pipe"), version 2
/// of its protocol, which goldfish kernels from 3.18 drive as
/// /dev/goldfish_pipe (/dev/qemu_pipe to Android). It multiplexes named
/// byte streams between guest processes and host services: the GPU's
/// "opengles", qemud's "qemud:boot-properties" and others.
///
/// Each guest pipe has a command page in guest RAM. The guest fills it
/// in and writes the pipe's id to CMD; the host reads it, acts, and
/// writes back a status. When a read or write can't go on, the guest asks
/// to be woken; the host later lists the pipe in the signal buffer and
/// raises the interrupt, and the guest reads GET_SIGNALLED to learn how
/// many entries there are.
public final class Pipe: device.Mmio {
    public static let Size: uint64 = 0x2000

    // Registers (drivers/platform/goldfish/goldfish_pipe_v2.c).
    static let regCmd: uint64 = 0
    static let regSignalBufferHigh: uint64 = 4
    static let regSignalBuffer: uint64 = 8
    static let regSignalBufferCount: uint64 = 12
    static let regOpenBufferHigh: uint64 = 20
    static let regOpenBuffer: uint64 = 24
    static let regVersion: uint64 = 36
    static let regGetSignalled: uint64 = 48

    /// The protocol this device speaks; a driver of version 4 or later
    /// uses it when the device reports 2 or more.
    static let deviceVersion: uint64 = 2

    // Commands.
    static let cmdOpen: int32 = 1
    static let cmdClose: int32 = 2
    static let cmdPoll: int32 = 3
    static let cmdWrite: int32 = 4
    static let cmdWakeOnWrite: int32 = 5
    static let cmdRead: int32 = 6
    static let cmdWakeOnRead: int32 = 7

    // Statuses.
    static let errInval: int32 = -1
    static let errAgain: int32 = -2
    static let errIo: int32 = -4

    // Wake flags.
    static let wakeClosed: uint32 = 1 << 0
    static let wakeRead: uint32 = 1 << 1
    static let wakeWrite: uint32 = 1 << 2

    // A command page: cmd, id, status, reserved, then for reads and
    // writes buffers_count, consumed_size, ptrs[336] and sizes[336].
    static let offStatus: uint64 = 8
    static let offBuffersCount: uint64 = 16
    static let offConsumed: uint64 = 20
    static let offPtrs: uint64 = 24
    static let maxBuffers: uint64 = 336
    static let offSizes: uint64 = 24 + 336 * 8

    /// The longest "pipe:<name>:<args>" the host accepts, as the emulator.
    static let maxConnectString = 128

    let memory: device.GuestMemory
    let irq: any device.Irq
    let lock = sync.Mutex()
    var services: [string: ServiceEntry] = [:]   // vsc_TODO #42
    var pipes: [uint32: Channel] = [:]
    var signalBuffer: uint64 = 0
    var signalCount: uint32 = 0
    var openBuffer: uint64 = 0
    /// Pipes with wakes the guest hasn't collected, in the order signalled.
    var signalled: [uint32] = []

    /// The names of the connections the guest asked for that no service
    /// answered, for diagnosing what an image expects.
    public private(set) var Refused: [string] = []

    public init(memory: device.GuestMemory, irq: any device.Irq) {
        self.memory = memory
        self.irq = irq
    }

    /// Answers connections to `name`: "opengles", or "qemud:boot-properties"
    /// (a qemud service is looked up by its full name first, then as
    /// "qemud" with the rest as its arguments, as the emulator does).
    public func Register(_ name: string, _ service: any PipeService) {
        lock.withLock { services[name] = ServiceEntry(service) }
    }

    /// How many pipes the guest has open.
    public var OpenCount: int { lock.withLock { pipes.count } }

    public func Read(offset: uint64, size: uint8) -> uint64 {
        switch offset {
        case Pipe.regVersion:
            // The driver reads the version as it probes: a rebooted guest's
            // old pipes are gone.
            resetAll()
            return Pipe.deviceVersion
        case Pipe.regGetSignalled:
            return uint64(collectSignalled())
        default:
            return 0
        }
    }

    public func Write(offset: uint64, size: uint8, value: uint64) {
        let v = value & 0xffff_ffff
        switch offset {
        case Pipe.regSignalBufferHigh: lock.withLock { signalBuffer = (signalBuffer & 0xffff_ffff) | v << 32 }
        case Pipe.regSignalBuffer: lock.withLock { signalBuffer = (signalBuffer & ~0xffff_ffff) | v }
        case Pipe.regSignalBufferCount: lock.withLock { signalCount = uint32(v) }
        case Pipe.regOpenBufferHigh: lock.withLock { openBuffer = (openBuffer & 0xffff_ffff) | v << 32 }
        case Pipe.regOpenBuffer: lock.withLock { openBuffer = (openBuffer & ~0xffff_ffff) | v }
        case Pipe.regCmd: command(uint32(v))
        default: break
        }
    }

    // MARK: commands

    func command(_ id: uint32) {
        if let ch = lock.withLock({ pipes[id] }) {
            run(ch)
            return
        }
        // Not open yet: this must be PIPE_CMD_OPEN, whose command page is
        // named in the open buffer.
        let open = lock.withLock { openBuffer }
        guard let pagePtr = try? memory.Load64(device.GuestAddress(open)) else { return }
        let cmdPage = device.GuestAddress(pagePtr)
        guard let cmd = try? memory.Load32(cmdPage) else { return }
        if int32(bitPattern: cmd) != Pipe.cmdOpen {
            store(cmdPage, Pipe.offStatus, Pipe.errInval)
            return
        }
        let ch = Channel(id: id, page: cmdPage)
        lock.withLock { pipes[id] = ch }
        store(cmdPage, Pipe.offStatus, 0)
    }

    func run(_ ch: Channel) {
        let page = ch.page
        guard let raw = try? memory.Load32(page) else { return }
        let cmd = int32(bitPattern: raw)
        if ch.hostClosed && cmd != Pipe.cmdClose {
            store(page, Pipe.offStatus, Pipe.errIo)
            return
        }
        switch cmd {
        case Pipe.cmdClose:
            lock.withLock {
                pipes[ch.id] = nil
                signalled.removeAll(where: { $0 == ch.id })
            }
            ch.conn?.Close()
            store(page, Pipe.offStatus, 0)
        case Pipe.cmdPoll:
            var f = PollFlags(readable: false, writable: true)
            if let c = ch.conn {
                f = PollFlags(readable: c.Readable, writable: c.Writable, hungUp: c.Closed)
            }
            store(page, Pipe.offStatus, int32(bitPattern: f.bits))
        case Pipe.cmdWrite, Pipe.cmdRead:
            let r = transfer(ch, write: cmd == Pipe.cmdWrite)
            store(page, Pipe.offConsumed, r > 0 ? r : 0)
            store(page, Pipe.offStatus, r)
        case Pipe.cmdWakeOnRead, Pipe.cmdWakeOnWrite:
            let read = cmd == Pipe.cmdWakeOnRead
            store(page, Pipe.offStatus, 0)
            let flag = read ? Pipe.wakeRead : Pipe.wakeWrite
            lock.withLock { ch.wanted = ch.wanted | flag }   // vsc_TODO #41
            // The state may have changed between the guest's failed
            // transfer and this request; then it must not wait for a wake
            // that has already happened.
            if let c = ch.conn {
                if c.Closed {
                    signal(ch.id, Pipe.wakeClosed)
                } else if read ? c.Readable : c.Writable {
                    signal(ch.id, read ? Pipe.wakeRead : Pipe.wakeWrite)
                }
            } else if !read {
                signal(ch.id, Pipe.wakeWrite)   // the connector always takes bytes
            }
        default:
            store(page, Pipe.offStatus, Pipe.errInval)
        }
    }

    /// The guest buffers of a read or write command, as (address, size).
    func buffers(_ page: device.GuestAddress) -> [(uint64, int)] {
        guard let n = try? memory.Load32(page.Adding(Pipe.offBuffersCount)) else { return [] }
        let count = min(uint64(n), Pipe.maxBuffers)
        var out: [(uint64, int)] = []
        var i: uint64 = 0
        while i < count {
            guard let p = try? memory.Load64(page.Adding(Pipe.offPtrs + i * 8)),
                  let s = try? memory.Load32(page.Adding(Pipe.offSizes + i * 4)) else { return [] }
            out.append((p, int(s)))
            i += 1
        }
        return out
    }

    /// A read or write: the status the guest gets, bytes moved when positive.
    func transfer(_ ch: Channel, write: bool) -> int32 {
        let bufs = buffers(ch.page)
        if bufs.isEmpty { return Pipe.errInval }
        if write {
            var bytes: [uint8] = []
            for (p, s) in bufs {
                guard let b = try? memory.Read(device.GuestAddress(p), count: s) else { return Pipe.errInval }
                bytes += b
            }
            guard let conn = ch.conn else { return connect(ch, bytes) }
            switch conn.Send(bytes) {
            case .done(let n): return int32(n)
            case .again: return Pipe.errAgain
            case .closed: return 0
            }
        }
        guard let conn = ch.conn else { return Pipe.errAgain }   // nothing to read before a service
        var total = 0
        for (_, s) in bufs { total += s }
        let got = conn.Receive(max: total)
        if got.isEmpty { return conn.Closed ? 0 : Pipe.errAgain }
        var at = 0
        for (p, s) in bufs {
            if at >= got.count { break }
            let n = min(s, got.count - at)
            do { try memory.Write(device.GuestAddress(p), Array(got[at..<at + n])) } catch { return Pipe.errInval }
            at += n
        }
        return int32(at)
    }

    /// Bytes written before a service is chosen: "pipe:<name>[:<args>]",
    /// up to a NUL. Returns how many were taken, or an error.
    func connect(_ ch: Channel, _ bytes: [uint8]) -> int32 {
        var taken = 0
        var complete = false
        for b in bytes {
            taken += 1
            if b == 0 { complete = true; break }
            ch.name.append(b)
            if ch.name.count >= Pipe.maxConnectString { return Pipe.errIo }
        }
        if !complete { return int32(taken) }
        let text = string(decoding: ch.name, as: UTF8.self)
        // A refused guest may try again on the same pipe, from the start.
        ch.name = []
        guard let (service, args) = lookup(text) else {
            lock.withLock { Refused.append(text) }
            return Pipe.errInval
        }
        guard let conn = service.Open(args, waker: Waker(pipe: self, id: ch.id)) else {
            lock.withLock { Refused.append(text) }
            return Pipe.errInval
        }
        ch.conn = conn
        return int32(taken)
    }

    /// The service a connect string names, and its arguments.
    func lookup(_ text: string) -> (any PipeService, string)? {
        let prefix = "pipe:"
        if !text.hasPrefix(prefix) { return nil }
        let rest = string(text.dropFirst(prefix.count))
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map { string($0) }
        return lock.withLock {
            // "qemud:<name>[:<args>]": a service named "qemud:<name>" first.
            if parts.count >= 2 && parts[0] == "qemud", let e = services["qemud:" + parts[1]] {
                return (e.Service, parts.count > 2 ? parts[2] : "")
            }
            let name = parts[0]
            let args = parts.count > 1 ? parts.dropFirst().joined(separator: ":") : ""
            if let e = services[name] { return (e.Service, args) }
            return nil
        }
    }

    // MARK: wakes

    func signal(_ id: uint32, _ flag: uint32) {
        lock.withLock {
            guard let ch = pipes[id] else { return }
            if flag == Pipe.wakeClosed {
                ch.hostClosed = true
                ch.pending |= flag
            } else if ch.wanted & flag != 0 {
                ch.wanted &= ~flag
                ch.pending |= flag
            } else {
                return
            }
            if !signalled.contains(id) { signalled.append(id) }
            irq.Set(true)
        }
    }

    /// GET_SIGNALLED: moves waiting wakes into the guest's signal buffer
    /// and returns how many there are.
    func collectSignalled() -> uint32 {
        lock.withLock {
            var n: uint32 = 0
            while n < signalCount && !signalled.isEmpty {
                let id = signalled.removeFirst()
                guard let ch = pipes[id] else { continue }
                let at = device.GuestAddress(signalBuffer + uint64(n) * 8)
                try? memory.Store32(at, id)
                try? memory.Store32(at.Adding(4), ch.pending)
                ch.pending = 0
                n += 1
            }
            if signalled.isEmpty { irq.Set(false) }
            return n
        }
    }

    func resetAll() {
        let old = lock.withLock {
            let o = Array(pipes.values)
            pipes = [:]
            signalled = []
            irq.Set(false)
            return o
        }
        for ch in old { ch.conn?.Close() }
    }

    func store(_ page: device.GuestAddress, _ offset: uint64, _ v: int32) {
        try? memory.Store32(page.Adding(offset), uint32(bitPattern: v))
    }
}

/// One guest pipe: its command page and, once named, its connection.
final class Channel {
    let id: uint32
    let page: device.GuestAddress
    /// The connect string so far, until a service is chosen.
    var name: [uint8] = []
    var conn: (any PipeConnection)? = nil
    /// Wakes the guest asked for and hasn't had.
    var wanted: uint32 = 0
    /// Wakes signalled and not yet collected through GET_SIGNALLED.
    var pending: uint32 = 0
    var hostClosed = false

    init(id: uint32, page: device.GuestAddress) {
        self.id = id
        self.page = page
    }
}

/// A registered service. (A dictionary of existentials can't be read
/// yet: vsc_TODO #42.)
final class ServiceEntry {
    let Service: any PipeService
    init(_ s: any PipeService) { Service = s }
}
