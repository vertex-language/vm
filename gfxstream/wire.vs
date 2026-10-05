// Package gfxstream is the host side of the Android emulator's render
// protocol: the byte stream a guest's EGL and GLES libraries write to
// the "opengles" pipe instead of drawing. Each call is a packet: its
// opcode, the packet's size, then its parameters. renderControl calls
// (the emulator's EGL) manage contexts, surfaces and color buffers here;
// GLES calls are carried out by a gles.Context.
//
// The calls and how each parameter travels come from the protocol's spec
// files (spec/), through vm/cmd/gen-gfxstream (signatures.vs).
package gfxstream

/// How one parameter travels on the wire.
public enum ParamKind: Equatable {
    /// A value of 1, 2, 4 or 8 bytes, little-endian.
    case value(int)
    /// A buffer the guest sends: a 4-byte length, then the bytes.
    case input
    /// A buffer the host fills: a 4-byte length; the bytes come back in the reply.
    case output
    /// Both: sent, and sent back.
    case inputOutput
}

/// One call the guest can make.
public struct Signature {
    public let Op: uint32
    public let Name: string
    public let Params: [ParamKind]
    /// The result's size in bytes, sent back after any outputs; 0 for none.
    public let Result: int

    public init(op: uint32, name: string, params: [ParamKind], result: int) {
        Op = op
        Name = name
        Params = params
        Result = result
    }
}

/// One argument of a decoded call.
public enum Arg {
    case value(uint64)
    case bytes([uint8])
    /// An output buffer of this many bytes.
    case output(int)
}

/// DecodeError is a packet this can't take apart.
public enum DecodeError: Error, Equatable {
    case unknownOpcode(uint32)
    /// The packet's parameters run past its stated size.
    case truncated(string)
}

/// A decoded call, and the reply being built for it: output buffers in
/// parameter order, then the result.
public final class Call {
    public let Sig: Signature
    public let Args: [Arg]
    var outputs: [[uint8]]
    var result: uint64 = 0

    init(_ sig: Signature, _ args: [Arg]) {
        Sig = sig
        Args = args
        // Outputs start zeroed; an inout buffer starts as what was sent.
        var outs: [[uint8]] = []
        for i in 0..<args.count {
            switch sig.Params[i] {
            case .output: outs.append([uint8](repeating: 0, count: outputSizeOf(args[i])))
            case .inputOutput: outs.append(bytesOf(args[i]))
            default: break
            }
        }
        outputs = outs
    }

    public var Name: string { Sig.Name }

    /// Argument `i` as an unsigned 32-bit value (GLenum, GLuint, GLsizei …).
    public func U32(_ i: int) -> uint32 {
        if case .value(let v) = Args[i] { return uint32(truncatingIfNeeded: v) }
        return 0
    }

    /// Argument `i` as a signed 32-bit value.
    public func I32(_ i: int) -> int32 { int32(bitPattern: U32(i)) }

    /// Argument `i` as a float (GLfloat, GLclampf).
    public func F32(_ i: int) -> float32 { float32(bitPattern: U32(i)) }

    /// Argument `i` as a 64-bit value.
    public func U64(_ i: int) -> uint64 {
        if case .value(let v) = Args[i] { return v }
        return 0
    }

    /// Argument `i` as a boolean (GLboolean).
    public func Bool(_ i: int) -> bool { U32(i) != 0 }

    /// Input buffer `i`'s bytes; empty for a null pointer.
    public func Bytes(_ i: int) -> [uint8] {
        switch Args[i] {
        case .bytes(let b): return b
        default: return []
        }
    }

    /// Input buffer `i` as text, up to its first NUL.
    public func Text(_ i: int) -> string {
        var b = Bytes(i)
        if let z = b.firstIndex(of: 0) { b = Array(b[0..<z]) }
        return string(decoding: b, as: UTF8.self)
    }

    /// Input buffer `i` as little-endian 32-bit words.
    public func Words(_ i: int) -> [uint32] {
        let b = Bytes(i)
        var out: [uint32] = []
        var k = 0
        while k + 4 <= b.count {
            out.append(uint32(b[k]) | uint32(b[k + 1]) << 8 | uint32(b[k + 2]) << 16 | uint32(b[k + 3]) << 24)
            k += 4
        }
        return out
    }

    /// The size of output buffer `i`.
    public func OutputSize(_ i: int) -> int {
        let o = outputIndex(i)
        return o < outputs.count ? outputs[o].count : 0
    }

    /// Which output (0, 1 …) argument `i` is.
    func outputIndex(_ i: int) -> int {
        var n = 0
        for k in 0..<i {
            switch Sig.Params[k] {
            case .output, .inputOutput: n += 1
            default: break
            }
        }
        return n
    }

    /// Fills output argument `i` with `bytes`, cut or zero-padded to its size.
    public func SetOutput(_ i: int, _ bytes: [uint8]) {
        let o = outputIndex(i)
        if o >= outputs.count { return }
        let n = outputs[o].count
        for k in 0..<min(n, bytes.count) { outputs[o][k] = bytes[k] }
    }

    /// Fills output argument `i` with little-endian 32-bit words.
    public func SetOutputWords(_ i: int, _ words: [uint32]) {
        var b: [uint8] = []
        for w in words { b += [uint8(w & 0xff), uint8((w >> 8) & 0xff), uint8((w >> 16) & 0xff), uint8(w >> 24)] }
        SetOutput(i, b)
    }

    /// The call's result.
    public func Return(_ v: uint64) { result = v }
    public func Return(_ v: int32) { result = uint64(uint32(bitPattern: v)) }
    public func Return(_ v: uint32) { result = uint64(v) }

    /// The bytes the guest reads back for this call; none when it reads nothing.
    var reply: [uint8] {
        var out: [uint8] = []
        for o in outputs { out += o }
        var r = result
        for _ in 0..<Sig.Result {
            out.append(uint8(r & 0xff))
            r >>= 8
        }
        return out
    }
}

func outputSizeOf(_ a: Arg) -> int {
    if case .output(let n) = a { return n }
    return 0
}

func bytesOf(_ a: Arg) -> [uint8] {
    if case .bytes(let b) = a { return b }
    return []
}

/// The calls of every API, by opcode.
public final class SignatureTable {
    var rc: [Signature] = []
    var gles1: [Signature] = []
    var gles2: [Signature] = []

    public init() {
        rc = renderControlSignatures
        gles1 = gles1Signatures
        gles2 = gles2Signatures
    }

    public func Find(_ op: uint32) -> Signature? {
        func at(_ list: [Signature]) -> Signature? {
            guard let first = list.first, op >= first.Op else { return nil }
            let i = int(op - first.Op)
            return i < list.count ? list[i] : nil
        }
        return at(rc) ?? at(gles2) ?? at(gles1)
    }
}

/// Splits a guest's byte stream into calls. Bytes arrive in pieces of any
/// size; a call is decoded once all of its packet is here.
public final class Decoder {
    let table: SignatureTable
    var buffer: [uint8] = []
    var start = 0

    public init(_ table: SignatureTable) {
        self.table = table
    }

    public func Append(_ bytes: [uint8]) {
        if start > 0 && start == buffer.count {
            buffer = []
            start = 0
        }
        buffer += bytes
    }

    /// Bytes received and not yet decoded.
    public var Pending: int { buffer.count - start }

    func u32(_ at: int) -> uint32 {
        uint32(buffer[at]) | uint32(buffer[at + 1]) << 8 | uint32(buffer[at + 2]) << 16 | uint32(buffer[at + 3]) << 24
    }

    /// The next whole call, or nil until more bytes come.
    public func Next() throws -> Call? {
        if Pending < 8 { return nil }
        let op = u32(start)
        let size = int(u32(start + 4))
        if size < 8 { throw DecodeError.truncated("packet of \(size) bytes") }
        if Pending < size { return nil }
        guard let sig = table.Find(op) else {
            start += size   // skip it, so one unknown call doesn't wedge the stream
            throw DecodeError.unknownOpcode(op)
        }
        let end = start + size
        var at = start + 8
        var args: [Arg] = []
        for p in sig.Params {
            switch p {
            case .value(let n):
                if at + n > end { throw DecodeError.truncated(sig.Name) }
                var v: uint64 = 0
                for k in 0..<n { v |= uint64(buffer[at + k]) << uint64(8 * k) }
                args.append(.value(v))
                at += n
            case .input, .inputOutput:
                if at + 4 > end { throw DecodeError.truncated(sig.Name) }
                let n = int(u32(at))
                at += 4
                if at + n > end { throw DecodeError.truncated(sig.Name) }
                args.append(.bytes(Array(buffer[at..<at + n])))
                at += n
            case .output:
                if at + 4 > end { throw DecodeError.truncated(sig.Name) }
                args.append(.output(int(u32(at))))
                at += 4
            }
        }
        start = end
        if start > 1 << 20 {
            buffer = Array(buffer[start...])
            start = 0
        }
        return Call(sig, args)
    }
}
