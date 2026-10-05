import (
    "vm/gfxstream"
)

/// A packet of the render protocol: opcode, size, then the arguments as
/// the guest's encoder lays them out.
func packet(_ op: uint32, _ args: [[uint8]]) -> [uint8] {
    var body: [uint8] = []
    for a in args { body += a }
    return le32(op) + le32(uint32(8 + body.count)) + body
}

func le32(_ v: uint32) -> [uint8] { [uint8(v & 0xff), uint8((v >> 8) & 0xff), uint8((v >> 16) & 0xff), uint8(v >> 24)] }
func f32(_ v: float32) -> [uint8] { le32(v.bitPattern) }
/// An input buffer: its length, then its bytes.
func buf(_ b: [uint8]) -> [uint8] { le32(uint32(b.count)) + b }
/// An output buffer: only its length.
func out(_ n: int) -> [uint8] { le32(uint32(n)) }

func words(_ b: [uint8]) -> [uint32] {
    var w: [uint32] = []
    var k = 0
    while k + 4 <= b.count {
        w.append(uint32(b[k]) | uint32(b[k + 1]) << 8 | uint32(b[k + 2]) << 16 | uint32(b[k + 3]) << 24)
        k += 4
    }
    return w
}

/// vm/gfxstream against packets laid out as the guest's encoder lays them
/// out: renderControl's queries, color buffers written and read back, and
/// a GL clear drawn through a window surface and posted.
func checkGfxstream() {
    let r = gfxstream.Renderer(width: 4, height: 4, dpi: 160)
    var posted: [uint8] = []
    r.OnPost = { px, w, h in posted = px }
    let c = r.Connect()
    func call(_ p: [uint8]) -> [uint8] {
        _ = c.Send(p)
        return c.Receive(max: 1 << 20)
    }
    _ = c.Send([0, 0, 0, 0])   // the client flags, before any call

    check(words(call(packet(10000, []))) == [1], "gfxstream: rcGetRendererVersion is 1")
    check(words(call(packet(10001, [out(4), out(4)]))) == [1, 4, 1], "gfxstream: rcGetEGLVersion is 1.4 (outputs, then the result)")
    let nc = words(call(packet(10004, [out(4)])))
    check(nc.count == 2 && nc[1] >= 1, "gfxstream: rcGetNumConfigs gives attributes and configs (\(nc))")
    // A query split across two writes still answers once whole.
    let q = packet(10003, [le32(0x1F02), out(64), le32(64)])   // rcGetGLString(GL_VERSION)
    _ = c.Send(Array(q[0..<10]))
    check(c.Receive(max: 64).isEmpty, "gfxstream: half a packet waits")
    let v = call(Array(q[10...]))
    check(string(decoding: v[0..<13], as: UTF8.self) == "OpenGL ES 2.0", "gfxstream: rcGetGLString answers once the packet is whole")

    // A 2×2 color buffer: write RGBA, read it back.
    let cb = words(call(packet(10012, [le32(2), le32(2), le32(0x1908)])))[0]
    let pixels: [uint8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    _ = call(packet(10024, [le32(cb), le32(0), le32(0), le32(2), le32(2), le32(0x1908), le32(0x1401), buf(pixels)]))
    let back = call(packet(10023, [le32(cb), le32(0), le32(0), le32(2), le32(2), le32(0x1908), le32(0x1401), out(16)]))
    check(back == pixels, "gfxstream: rcUpdateColorBuffer then rcReadColorBuffer round-trips")

    // A context and window surface on a 4×4 color buffer; clear it red; post it.
    let ctx = words(call(packet(10008, [le32(1), le32(0), le32(2)])))[0]
    let surf = words(call(packet(10010, [le32(1), le32(4), le32(4)])))[0]
    let fb = words(call(packet(10012, [le32(4), le32(4), le32(0x1908)])))[0]
    _ = call(packet(10015, [le32(surf), le32(fb)]))
    check(words(call(packet(10017, [le32(ctx), le32(surf), le32(surf)]))) == [1], "gfxstream: rcMakeCurrent")
    _ = call(packet(2064, [f32(1), f32(0), f32(0), f32(0.5)]))   // glClearColor
    _ = call(packet(2063, [le32(0x4000)]))                        // glClear(GL_COLOR_BUFFER_BIT)
    check(words(call(packet(2108, []))) == [0], "gfxstream: glGetError is GL_NO_ERROR")
    _ = call(packet(10018, [le32(fb)]))                           // rcFBPost
    check(posted.count == 64 && Array(posted[0..<4]) == [255, 0, 0, 255], "gfxstream: a cleared window surface posts red, opaque (\(Array(posted.prefix(4))))")
    check(r.Errors.isEmpty, "gfxstream: no stream errors (\(r.Errors))")
}
