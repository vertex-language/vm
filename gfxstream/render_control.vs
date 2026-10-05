package gfxstream

import (
    "gles"
    "gles/fixed"
    "gpu/raster"
)

// GL and EGL values the render protocol carries.
let glRgba: uint32 = 0x1908
let glRgb: uint32 = 0x1907
let glRgb8: uint32 = 0x8051
let glRgb565: uint32 = 0x8D62
let glBgraExt: uint32 = 0x80E1
let glUnsignedByte: uint32 = 0x1401
let glUnsignedShort565: uint32 = 0x8363
let glVendor: uint32 = 0x1F00
let glRenderer: uint32 = 0x1F01
let glVersion: uint32 = 0x1F02
let glExtensions: uint32 = 0x1F03
let glShadingLanguageVersion: uint32 = 0x8B8C
let eglVendor: uint32 = 0x3053
let eglVersion: uint32 = 0x3054
let eglExtensions: uint32 = 0x3055
let eglClientApis: uint32 = 0x308D

/// What rcGetGLString reports. GLES 2.0, with the extensions Android's
/// compositor and UI rely on.
let hostGlExtensions = "GL_OES_EGL_image GL_OES_EGL_image_external GL_OES_texture_npot GL_OES_rgb8_rgba8 " +
    "GL_OES_depth24 GL_OES_packed_depth_stencil GL_OES_element_index_uint GL_OES_standard_derivatives " +
    "GL_EXT_texture_format_BGRA8888 GL_OES_vertex_array_object "

/// The EGL config attributes, in the order rcGetConfigs's first row lists
/// them, and the configs: color (r, g, b, a), then depth and stencil.
let configAttribs: [uint32] = [
    0x3025, 0x3026, 0x3040, 0x3033, 0x3028,   // DEPTH, STENCIL, RENDERABLE_TYPE, SURFACE_TYPE, CONFIG_ID
    0x3020, 0x3021, 0x3022, 0x3023, 0x3024,   // BUFFER, ALPHA, BLUE, GREEN, RED sizes
    0x3027, 0x3029, 0x302A, 0x302B, 0x302C,   // CONFIG_CAVEAT, LEVEL, MAX_PBUFFER_HEIGHT, _PIXELS, _WIDTH
    0x302D, 0x302F, 0x3031, 0x3032, 0x3034,   // NATIVE_RENDERABLE, NATIVE_VISUAL_TYPE, SAMPLES, SAMPLE_BUFFERS, TRANSPARENT_TYPE
    0x3039, 0x303A, 0x303B, 0x303C, 0x303D,   // BIND_TO_TEXTURE_RGB, _RGBA, MIN_SWAP, MAX_SWAP, LUMINANCE_SIZE
    0x303E, 0x303F, 0x3042, 0x3142,           // ALPHA_MASK_SIZE, COLOR_BUFFER_TYPE, CONFORMANT, RECORDABLE_ANDROID
]

struct ConfigShape {
    let r: uint32
    let g: uint32
    let b: uint32
    let a: uint32
    let depth: uint32
    let stencil: uint32
}

let configShapes: [ConfigShape] = [
    ConfigShape(r: 8, g: 8, b: 8, a: 8, depth: 0, stencil: 0),
    ConfigShape(r: 8, g: 8, b: 8, a: 8, depth: 24, stencil: 8),
    ConfigShape(r: 8, g: 8, b: 8, a: 0, depth: 0, stencil: 0),
    ConfigShape(r: 8, g: 8, b: 8, a: 0, depth: 24, stencil: 8),
    ConfigShape(r: 5, g: 6, b: 5, a: 0, depth: 0, stencil: 0),
    ConfigShape(r: 5, g: 6, b: 5, a: 0, depth: 24, stencil: 8),
]

/// Config `i`'s value for each of configAttribs.
func configRow(_ i: int) -> [uint32] {
    let c = configShapes[i]
    let esBits: uint32 = 0x1 | 0x4             // EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT
    let surfaces: uint32 = 0x4 | 0x1           // EGL_WINDOW_BIT | EGL_PBUFFER_BIT
    return [
        c.depth, c.stencil, esBits, surfaces, uint32(i + 1),
        c.r + c.g + c.b + c.a, c.a, c.b, c.g, c.r,
        0x3038, 0, 4096, 4096 * 4096, 4096,      // caveat EGL_NONE
        0, 0, 0, 0, 0x3038,                      // transparent type EGL_NONE
        1, c.a > 0 ? 1 : 0, 0, 1, 0,
        0, 0x308E, esBits, 1,                    // EGL_RGB_BUFFER; recordable
    ]
}

/// Whether config `i` meets an eglChooseConfig attribute list.
func configMatches(_ i: int, _ attribs: [uint32]) -> bool {
    let row = configRow(i)
    var k = 0
    while k + 1 < attribs.count {
        let name = attribs[k]
        let want = attribs[k + 1]
        k += 2
        if name == 0x3038 { break }                    // EGL_NONE
        if want == 0xFFFF_FFFF { continue }            // EGL_DONT_CARE
        guard let at = configAttribs.firstIndex(of: name) else { continue }
        let have = row[at]
        switch name {
        case 0x3040, 0x3033, 0x3042:                   // masks: every bit asked for
            if have & want != want { return false }
        case 0x3028, 0x302D, 0x302F, 0x3034, 0x3029, 0x303F, 0x3039, 0x303A, 0x3142, 0x3027:
            if have != want { return false }           // exact
        case 0x303B:
            if have > want { return false }
        case 0x303C:
            if have < want { return false }
        default:                                        // sizes: at least
            if have < want { return false }
        }
    }
    return true
}

extension RenderConnection {
    func renderControl(_ c: Call) {
        let r = renderer
        switch c.Name {
        case "rcGetRendererVersion":
            c.Return(uint32(1))
        case "rcGetEGLVersion":
            c.SetOutputWords(0, [1])
            c.SetOutputWords(1, [4])
            c.Return(uint32(1))
        case "rcQueryEGLString":
            let s: string
            switch c.U32(0) {
            case eglVendor: s = "Vertex"
            case eglVersion: s = "1.4"
            case eglClientApis: s = "OpenGL_ES"
            case eglExtensions: s = "EGL_KHR_image_base EGL_KHR_gl_texture_2D_image "
            default: s = ""
            }
            returnString(c, s, bufferArg: 1, sizeArg: 2)
        case "rcGetGLString":
            let s: string
            switch c.U32(0) {
            case glVendor: s = "Vertex"
            case glRenderer: s = "Vertex gles (CPU)"
            case glVersion: s = "OpenGL ES 2.0"
            case glShadingLanguageVersion: s = "OpenGL ES GLSL ES 1.00"
            case glExtensions: s = hostGlExtensions
            default: s = ""
            }
            returnString(c, s, bufferArg: 1, sizeArg: 2)
        case "rcGetNumConfigs":
            c.SetOutputWords(0, [uint32(configAttribs.count)])
            c.Return(uint32(configShapes.count))
        case "rcGetConfigs":
            var words = configAttribs
            for i in 0..<configShapes.count { words += configRow(i) }
            c.SetOutputWords(1, words)
            c.Return(uint32(configShapes.count))
        case "rcChooseConfig":
            let attribs = c.Words(0)
            var ids: [uint32] = []
            for i in 0..<configShapes.count where configMatches(i, attribs) { ids.append(uint32(i + 1)) }
            let room = c.OutputSize(2) / 4
            c.SetOutputWords(2, Array(ids.prefix(room)))
            c.Return(uint32(room > 0 ? min(room, ids.count) : ids.count))
        case "rcGetFBParam":
            switch c.U32(0) {
            case 1: c.Return(uint32(r.Width))
            case 2: c.Return(uint32(r.Height))
            case 3, 4: c.Return(uint32(r.Dpi))
            case 5: c.Return(uint32(60))
            case 6: c.Return(uint32(1))
            case 7: c.Return(uint32(1))
            default: c.Return(uint32(0))
            }
        case "rcCreateContext":
            let h = r.handle()
            let info = ContextInfo(handle: h, config: c.U32(0), share: c.U32(1), version: c.U32(2))
            r.lock.withLock { r.contexts[h] = info }
            c.Return(h)
        case "rcDestroyContext":
            let h = c.U32(0)
            r.lock.withLock { r.contexts[h] = nil }
        case "rcCreateWindowSurface":
            let h = r.handle()
            let config = int(c.U32(0)) - 1
            let depth = config >= 0 && config < configShapes.count && configShapes[config].depth > 0
            let s = WindowSurface(handle: h, width: int(c.U32(1)), height: int(c.U32(2)), wantsDepth: depth)
            r.lock.withLock { r.surfaces[h] = s }
            c.Return(h)
        case "rcDestroyWindowSurface":
            let h = c.U32(0)
            r.lock.withLock { r.surfaces[h] = nil }
        case "rcCreateColorBuffer", "rcCreateColorBufferDMA":
            let h = r.handle()
            let cb = ColorBuffer(handle: h, width: int(c.U32(0)), height: int(c.U32(1)), internalFormat: c.U32(2))
            r.lock.withLock { r.colorBuffers[h] = cb }
            c.Return(h)
        case "rcOpenColorBuffer", "rcOpenColorBuffer2":
            let h = c.U32(0)
            let ok = r.lock.withLock { () -> bool in
                guard let cb = r.colorBuffers[h] else { return false }
                cb.refs += 1
                return true
            }
            c.Return(ok ? int32(0) : int32(-1))
        case "rcCloseColorBuffer":
            let h = c.U32(0)
            r.lock.withLock {
                if let cb = r.colorBuffers[h] {
                    cb.refs -= 1
                    if cb.refs <= 0 { r.colorBuffers[h] = nil }
                }
            }
        case "rcSetWindowColorBuffer":
            let s = c.U32(0)
            let b = c.U32(1)
            r.lock.withLock { r.surfaces[s]?.Buffer = b }
            if s == drawSurface { bindSurface() }
        case "rcFlushWindowColorBuffer":
            c.Return(int32(0))
        case "rcFlushWindowColorBufferAsync":
            break
        case "rcMakeCurrent":
            context = c.U32(0)
            drawSurface = c.U32(1)
            readSurface = c.U32(2)
            gl = context == 0 ? nil : glContext(context)
            gl1 = context == 0 ? nil : r.lock.withLock { r.contexts[context]?.GL1 }
            bindSurface()
            c.Return(uint32(1))
        case "rcFBPost":
            if let cb = r.colorBuffer(c.U32(0)), let post = r.OnPost {
                // The screen has no alpha: what's posted shows opaque.
                var px = cb.Pixels
                px.withUnsafeMutableBufferPointer { p in
                    var k = 3
                    while k < p.count {
                        p[k] = 255
                        k += 4
                    }
                }
                post(px, cb.Width, cb.Height)
            }
        case "rcBindTexture":
            // The guest's EGL image (a color buffer) becomes the bound
            // 2D texture's image; its encoder maps external textures to 2D.
            if let cb = r.colorBuffer(c.U32(0)), let g = gl { g.BindImage(0x0DE1, cb.Texture) }
        case "rcBindRenderbuffer":
            if let cb = r.colorBuffer(c.U32(0)), let g = gl { g.BindRenderbufferImage(cb.Texture) }
        case "rcCreateClientImage":
            r.note(c.Name)
            c.Return(uint32(0))
        case "rcDestroyClientImage":
            c.Return(int32(0))
        case "rcFBSetSwapInterval":
            break
        case "rcColorBufferCacheFlush":
            c.Return(int32(0))
        case "rcUpdateColorBuffer":
            if let cb = r.colorBuffer(c.U32(0)) {
                writePixels(cb, x: int(c.I32(1)), y: int(c.I32(2)), width: int(c.I32(3)), height: int(c.I32(4)),
                            format: c.U32(5), type: c.U32(6), c.Bytes(7))
            }
            c.Return(int32(0))
        case "rcReadColorBuffer":
            if let cb = r.colorBuffer(c.U32(0)) {
                c.SetOutput(7, readPixels(cb, x: int(c.I32(1)), y: int(c.I32(2)), width: int(c.I32(3)), height: int(c.I32(4)),
                                          format: c.U32(5), type: c.U32(6)))
            }
        case "rcSelectChecksumHelper", "rcSetPuid":
            break
        default:
            r.note(c.Name)
        }
    }

    /// The GLES context for a guest context handle, made the first time,
    /// sharing objects with the context it was created to share with.
    func glContext(_ h: uint32) -> gles.Context? {
        let r = renderer
        guard let info = r.lock.withLock({ r.contexts[h] }) else { return nil }
        if let g = info.GL { return g }
        var share: gles.ShareGroup? = nil
        if info.Share != 0, let s = r.lock.withLock({ r.contexts[info.Share] }), let sg = s.GL {
            share = sg.Shared
        }
        if info.Version == 1 {
            let f = fixed.Context(share: share)
            info.GL1 = f
            info.GL = f.GL
            return f.GL
        }
        let g = gles.Context(version: info.Version >= 3 ? .es3 : .es2, share: share)
        info.GL = g
        return g
    }

    /// Points the current context's framebuffer 0 at the draw surface's color buffer.
    func bindSurface() {
        guard let g = gl else { return }
        let r = renderer
        guard let s = r.lock.withLock({ r.surfaces[drawSurface] }), let cb = r.colorBuffer(s.Buffer) else {
            g.SetDefaultFramebuffer(color: nil, depth: nil)
            return
        }
        if s.WantsDepth && (s.Depth == nil || s.Depth!.Width != cb.Width || s.Depth!.Height != cb.Height) {
            s.Depth = raster.Texture(width: cb.Width, height: cb.Height, format: .depthStencil)
        }
        g.SetDefaultFramebuffer(color: cb.Texture, depth: s.Depth)
    }

    /// The rcQueryEGLString / rcGetGLString convention: the string and its
    /// NUL if it fits, else minus the size it needs.
    func returnString(_ c: Call, _ s: string, bufferArg: int, sizeArg: int) {
        var b = Array(s.utf8)
        b.append(0)
        let room = c.OutputSize(bufferArg)
        if b.count > room {
            c.Return(int32(-b.count))
            return
        }
        c.SetOutput(bufferArg, b)
        c.Return(int32(b.count))
    }
}

/// Bytes per pixel of a GL format and type pair the color buffers take.
func pixelSize(_ format: uint32, _ type: uint32) -> int {
    if type == glUnsignedShort565 { return 2 }
    if format == glRgb { return 3 }
    return 4
}

/// Writes guest pixels into a color buffer, converting them to RGBA.
func writePixels(_ cb: ColorBuffer, x: int, y: int, width: int, height: int, format: uint32, type: uint32, _ src: [uint8]) {
    let lv = cb.Texture.Write(level: 0)!
    let bpp = pixelSize(format, type)
    if width <= 0 || height <= 0 || src.count < width * height * bpp { return }
    for row in 0..<height {
        let dy = y + row
        if dy < 0 || dy >= cb.Height { continue }
        for col in 0..<width {
            let dx = x + col
            if dx < 0 || dx >= cb.Width { continue }
            let s = (row * width + col) * bpp
            let d = (dy * cb.Width + dx) * 4
            if type == glUnsignedShort565 {
                let v = uint32(src[s]) | uint32(src[s + 1]) << 8
                let r5 = (v >> 11) & 0x1f
                let g6 = (v >> 5) & 0x3f
                let b5 = v & 0x1f
                lv.Bytes[d] = uint8((r5 << 3) | (r5 >> 2))
                lv.Bytes[d + 1] = uint8((g6 << 2) | (g6 >> 4))
                lv.Bytes[d + 2] = uint8((b5 << 3) | (b5 >> 2))
                lv.Bytes[d + 3] = 255
            } else if format == glBgraExt {
                lv.Bytes[d] = src[s + 2]
                lv.Bytes[d + 1] = src[s + 1]
                lv.Bytes[d + 2] = src[s]
                lv.Bytes[d + 3] = src[s + 3]
            } else if bpp == 3 {
                lv.Bytes[d] = src[s]
                lv.Bytes[d + 1] = src[s + 1]
                lv.Bytes[d + 2] = src[s + 2]
                lv.Bytes[d + 3] = 255
            } else {
                lv.Bytes[d] = src[s]
                lv.Bytes[d + 1] = src[s + 1]
                lv.Bytes[d + 2] = src[s + 2]
                lv.Bytes[d + 3] = cb.opaque ? 255 : src[s + 3]
            }
        }
    }
}

/// Reads a color buffer's pixels out in the guest's format.
func readPixels(_ cb: ColorBuffer, x: int, y: int, width: int, height: int, format: uint32, type: uint32) -> [uint8] {
    let lv = cb.Texture.Read(level: 0)!
    let bpp = pixelSize(format, type)
    if width <= 0 || height <= 0 { return [] }
    var out = [uint8](repeating: 0, count: width * height * bpp)
    for row in 0..<height {
        let sy = y + row
        if sy < 0 || sy >= cb.Height { continue }
        for col in 0..<width {
            let sx = x + col
            if sx < 0 || sx >= cb.Width { continue }
            let s = (sy * cb.Width + sx) * 4
            let d = (row * width + col) * bpp
            if type == glUnsignedShort565 {
                let v = (uint32(lv.Bytes[s]) >> 3) << 11 | (uint32(lv.Bytes[s + 1]) >> 2) << 5 | uint32(lv.Bytes[s + 2]) >> 3
                out[d] = uint8(v & 0xff)
                out[d + 1] = uint8(v >> 8)
            } else if format == glBgraExt {
                out[d] = lv.Bytes[s + 2]
                out[d + 1] = lv.Bytes[s + 1]
                out[d + 2] = lv.Bytes[s]
                out[d + 3] = lv.Bytes[s + 3]
            } else {
                for k in 0..<bpp { out[d + k] = lv.Bytes[s + k] }
            }
        }
    }
    return out
}
