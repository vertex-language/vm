package gfxstream

import (
    "fs"
    "gles"
    "gles/fixed"
    "gpu/raster"
    "sync"
    "vm/goldfish"
)

/// A color buffer: an image the guest's gralloc allocates (a window's
/// buffer, a texture's backing), shared by every guest process. Its
/// texture is RGBA, 8 bits each, top row first, as gralloc's CPU writes
/// it; GL draws into it upside down (a window surface's FlipY) and reads
/// it as a texture as it lies, as the emulator does.
public final class ColorBuffer {
    public let Handle: uint32
    public let Width: int
    public let Height: int
    /// The GL format the guest asked for (GL_RGBA, GL_RGB, GL_RGB565 …).
    public let InternalFormat: uint32
    public let Texture: raster.Texture
    var refs = 1

    init(handle: uint32, width: int, height: int, internalFormat: uint32) {
        Handle = handle
        Width = width
        Height = height
        InternalFormat = internalFormat
        Texture = raster.Texture(width: max(1, width), height: max(1, height), format: .rgba8)
    }

    /// The pixels, RGBA rows top first.
    public var Pixels: [uint8] { Texture.Read(level: 0)!.ByteArray }

    /// Whether the format has no alpha, so alpha reads as 1.
    var opaque: bool { InternalFormat == glRgb || InternalFormat == glRgb565 || InternalFormat == glRgb8 }
}

/// A guest's EGL window surface: what a context draws to, shown through
/// the color buffer the guest sets on it.
final class WindowSurface {
    let Handle: uint32
    var Width: int
    var Height: int
    var Buffer: uint32 = 0
    /// Whether its config asks for depth and stencil.
    let WantsDepth: bool
    /// Depth and stencil, sized to the color buffer when it's set.
    var Depth: raster.Texture? = nil

    init(handle: uint32, width: int, height: int, wantsDepth: bool) {
        Handle = handle
        Width = width
        Height = height
        WantsDepth = wantsDepth
    }
}

/// A guest's EGL context: its config and GLES version, and what it shares.
final class ContextInfo {
    let Handle: uint32
    let Config: uint32
    let Share: uint32
    let Version: uint32
    /// The GLES context, made when it is first current.
    var GL: gles.Context? = nil
    /// For a GLES 1.1 context: its fixed-function state (GL is its GLES 2 context).
    var GL1: fixed.Context? = nil

    init(handle: uint32, config: uint32, share: uint32, version: uint32) {
        Handle = handle
        Config = config
        Share = share
        Version = version
    }
}

/// The host renderer: the "opengles" pipe service. It holds what every
/// guest process shares (color buffers, contexts, surfaces) and gives each
/// guest render thread its own connection.
public final class Renderer: goldfish.PipeService {
    /// The display's size in pixels and density, as the guest's gralloc asks.
    public let Width: int
    public let Height: int
    public let Dpi: int
    /// Called with each frame the guest posts (rcFBPost): RGBA rows, top first.
    public var OnPost: (([uint8], int, int) -> Void)? = nil
    /// Notes each GLES call that leaves a GL error, by name (Unimplemented lists them as "name → error").
    public var DebugErrors = false
    /// Where to keep every connection's byte stream, interleaved as it
    /// came (Recording), for replaying in checks and tools.
    public var RecordDir: string? = nil
    var recording: Recording? = nil

    let table = SignatureTable()
    let lock = sync.Mutex()
    /// One GPU: every connection's calls run one at a time.
    let gpu = sync.Mutex()
    var colorBuffers: [uint32: ColorBuffer] = [:]
    var surfaces: [uint32: WindowSurface] = [:]
    var contexts: [uint32: ContextInfo] = [:]
    var nextHandle: uint32 = 1
    var connections = 0
    var unimplemented: [string: int] = [:]
    var errors: [string] = []

    public init(width: int, height: int, dpi: int) {
        Width = width
        Height = height
        Dpi = dpi
    }

    /// Draws on the host's GPU (Metal) from now on; false when it has
    /// none, and the CPU draws.
    public func UseGPU() -> bool {
        return raster.EnableGPU()
    }

    /// What the GPU has drawn, and what fell back to the CPU.
    public var GPUStats: raster.GPUStats { raster.GPUCounters }

    public func Open(_ args: string, waker: goldfish.Waker) -> (any goldfish.PipeConnection)? {
        let n = lock.withLock {
            connections += 1
            return connections
        }
        if let dir = RecordDir, recording == nil {
            recording = try? Recording(create: dir + "/opengles.rec")
        }
        return RenderConnection(renderer: self, waker: waker, id: uint32(n))
    }

    /// A connection that isn't on a pipe: for tests and tools that speak
    /// the protocol in-process. Send writes calls; Receive reads replies.
    public func Connect() -> RenderConnection {
        let n = lock.withLock {
            connections += 1
            return connections
        }
        return RenderConnection(renderer: self, waker: nil, id: uint32(n))
    }

    /// The GLES calls the guest made that aren't carried out yet, most used first.
    public var Unimplemented: [(string, int)] {
        lock.withLock { unimplemented.map { ($0.key, $0.value) }.sorted(by: { $0.1 > $1.1 }) }
    }

    /// Decoding errors, for diagnosing a stream this can't follow.
    public var Errors: [string] { lock.withLock { errors } }

    func handle() -> uint32 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            return h
        }
    }

    func note(_ name: string) {
        lock.withLock { unimplemented[name] = (unimplemented[name] ?? 0) + 1 }
    }

    func fail(_ what: string) {
        lock.withLock { if errors.count < 100 { errors.append(what) } }
    }

    func colorBuffer(_ h: uint32) -> ColorBuffer? { lock.withLock { colorBuffers[h] } }
}

/// One guest render thread's stream: calls in, replies out.
public final class RenderConnection: goldfish.PipeConnection {
    let renderer: Renderer
    let waker: goldfish.Waker?
    let decoder: Decoder
    let id: uint32
    let lock = sync.Mutex()
    var outgoing: [uint8] = []
    var closed = false
    /// The client flags the guest sends before its first call.
    var flagsLeft = 4
    var context: uint32 = 0
    var drawSurface: uint32 = 0
    var readSurface: uint32 = 0
    /// The current context's GLES state.
    var gl: gles.Context? = nil
    /// The current context's GLES 1.1 state, when it is a 1.1 context (gl is then its GLES 2 context).
    var gl1: fixed.Context? = nil

    init(renderer: Renderer, waker: goldfish.Waker?, id: uint32) {
        self.renderer = renderer
        self.waker = waker
        self.id = id
        decoder = Decoder(renderer.table)
    }

    public func Send(_ bytes: [uint8]) -> goldfish.Transfer {
        renderer.recording?.Add(id, bytes)
        var data = bytes
        if flagsLeft > 0 {
            let n = min(flagsLeft, data.count)
            flagsLeft -= n
            data = Array(data[n...])
        }
        decoder.Append(data)
        let reply = renderer.gpu.withLock { drain() }   // vsc_TODO #50: the loop in a method
        if !reply.isEmpty {
            lock.withLock { outgoing += reply }
            waker?.Readable()
        }
        return .done(bytes.count)
    }

    /// Runs every whole call received; returns what the guest reads back.
    func drain() -> [uint8] {
        var reply: [uint8] = []
        while true {
            do {
                guard let call = try decoder.Next() else { break }
                execute(call)
                reply += call.reply
            } catch {
                renderer.fail("\(error)")
            }
        }
        return reply
    }

    public func Receive(max: int) -> [uint8] {
        lock.withLock {
            let n = min(max, outgoing.count)
            let out = Array(outgoing[0..<n])
            outgoing.removeFirst(n)
            return out
        }
    }

    public var Closed: bool { lock.withLock { closed } }
    public var Readable: bool { lock.withLock { !outgoing.isEmpty } }
    public var Writable: bool { true }

    public func Close() {
        lock.withLock { closed = true }
    }

    func execute(_ call: Call) {
        if call.Sig.Op >= 10000 {
            renderControl(call)
        } else {
            gles(call)
        }
    }
}

/// A recording of a render stream: each piece any connection sent, in
/// the order it came, as [connection u32][length u32][bytes].
public final class Recording {
    let file: fs.File
    let lock = sync.Mutex()

    public init(create path: string) throws {
        file = try fs.Create(fs.Path(path))
    }

    func Add(_ connection: uint32, _ bytes: [uint8]) {
        var head: [uint8] = []
        for v in [connection, uint32(bytes.count)] {
            head += [uint8(v & 0xff), uint8((v >> 8) & 0xff), uint8((v >> 16) & 0xff), uint8(v >> 24)]
        }
        lock.withLock {
            try? file.Write(head)
            try? file.Write(bytes)
        }
    }
}

/// Feeds a recording through a renderer again, connection by connection
/// as it came; returns how many pieces it replayed.
public func Replay(_ data: [uint8], into r: Renderer) -> int {
    var conns: [uint32: RenderConnection] = [:]
    var at = 0
    var n = 0
    func u32(_ k: int) -> uint32 { uint32(data[k]) | uint32(data[k + 1]) << 8 | uint32(data[k + 2]) << 16 | uint32(data[k + 3]) << 24 }
    while at + 8 <= data.count {
        let id = u32(at)
        let len = int(u32(at + 4))
        at += 8
        if at + len > data.count { break }
        let conn = conns[id] ?? RenderConnection(renderer: r, waker: nil, id: id)
        conns[id] = conn
        _ = conn.Send(Array(data[at..<at + len]))
        _ = conn.Receive(max: 1 << 30)
        at += len
        n += 1
    }
    return n
}
