package gfxstream

import (
    "gles"
)

extension Call {
    /// Input buffer `i` as floats.
    func Floats(_ i: int) -> [float32] { Words(i).map { float32(bitPattern: $0) } }
    /// Input buffer `i` as GLints.
    func Ints(_ i: int) -> [int32] { Words(i).map { int32(bitPattern: $0) } }
}

/// The bytes of a string with its NUL, cut to fit a buffer of `size`.
func cString(_ s: string, size: int) -> [uint8] {
    if size <= 0 { return [] }
    var b = Array(s.utf8)
    if b.count > size - 1 { b = Array(b[0..<(size - 1)]) }
    b.append(0)
    return b
}

func wordsOf(_ v: [int32]) -> [uint32] { v.map { uint32(bitPattern: $0) } }

extension RenderConnection {
    /// A GLES call, for the current context.
    func gles(_ c: Call) {
        guard let g = gl else {
            renderer.note(c.Name + " (no context)")
            return
        }
        let before = renderer.DebugErrors ? g.PendingError : gles.Error.none   // vsc_TODO #51
        defer {
            if renderer.DebugErrors && before == .none && g.PendingError != .none {
                renderer.note("\(c.Name) → \(g.PendingError)")
            }
        }
        if c.Sig.Op < 2048 {
            guard let f = gl1 else {
                renderer.note(c.Name + " (not a 1.1 context)")
                return
            }
            gles1(c, f)
            return
        }
        gles2(c, g)
    }

    /// A GLES 2 call, or a 1.1 call with the same signature, on `g`.
    func gles2(_ c: Call, _ g: gles.Context) {
        switch c.Name {
        // MARK: state
        case "glActiveTexture": g.ActiveTexture(c.U32(0))
        case "glBlendColor": g.BlendColor(c.F32(0), c.F32(1), c.F32(2), c.F32(3))
        case "glBlendEquation": g.BlendEquation(c.U32(0))
        case "glBlendEquationSeparate": g.BlendEquationSeparate(c.U32(0), c.U32(1))
        case "glBlendFunc": g.BlendFunc(c.U32(0), c.U32(1))
        case "glBlendFuncSeparate": g.BlendFuncSeparate(c.U32(0), c.U32(1), c.U32(2), c.U32(3))
        case "glClearColor": g.ClearColor(c.F32(0), c.F32(1), c.F32(2), c.F32(3))
        case "glClearDepthf": g.ClearDepthf(c.F32(0))
        case "glClearStencil": g.ClearStencil(c.I32(0))
        case "glColorMask": g.ColorMask(c.Bool(0), c.Bool(1), c.Bool(2), c.Bool(3))
        case "glCullFace": g.CullFace(c.U32(0))
        case "glDepthFunc": g.DepthFunc(c.U32(0))
        case "glDepthMask": g.DepthMask(c.Bool(0))
        case "glDepthRangef": g.DepthRangef(c.F32(0), c.F32(1))
        case "glDisable": g.Disable(c.U32(0))
        case "glEnable": g.Enable(c.U32(0))
        case "glFrontFace": g.FrontFace(c.U32(0))
        case "glHint": g.Hint(c.U32(0), c.U32(1))
        case "glLineWidth": g.LineWidth(c.F32(0))
        case "glPixelStorei": g.PixelStorei(c.U32(0), c.I32(1))
        case "glPolygonOffset": g.PolygonOffset(c.F32(0), c.F32(1))
        case "glSampleCoverage": g.SampleCoverage(c.F32(0), c.Bool(1))
        case "glScissor": g.Scissor(c.I32(0), c.I32(1), c.I32(2), c.I32(3))
        case "glStencilFunc": g.StencilFunc(c.U32(0), c.I32(1), c.U32(2))
        case "glStencilFuncSeparate": g.StencilFuncSeparate(c.U32(0), c.U32(1), c.I32(2), c.U32(3))
        case "glStencilMask": g.StencilMask(c.U32(0))
        case "glStencilMaskSeparate": g.StencilMaskSeparate(c.U32(0), c.U32(1))
        case "glStencilOp": g.StencilOp(c.U32(0), c.U32(1), c.U32(2))
        case "glStencilOpSeparate": g.StencilOpSeparate(c.U32(0), c.U32(1), c.U32(2), c.U32(3))
        case "glViewport": g.Viewport(c.I32(0), c.I32(1), c.I32(2), c.I32(3))
        case "glIsEnabled": c.Return(uint32(g.IsEnabled(c.U32(0)) ? 1 : 0))
        case "glGetError": c.Return(g.GetError())
        case "glFinish": g.Finish()
        case "glFlush": g.Flush()
        case "glFinishRoundTrip":
            g.Finish()
            c.Return(int32(0))
        case "glGetIntegerv":
            if let v = g.Get(c.U32(0)) { c.SetOutputWords(1, wordsOf(v.Ints)) }
        case "glGetFloatv":
            if let v = g.Get(c.U32(0)) { c.SetOutputWords(1, v.Floats.map { $0.bitPattern }) }
        case "glGetBooleanv":
            if let v = g.Get(c.U32(0)) { c.SetOutput(1, v.Bools.map { $0 ? 1 : 0 }) }
        case "glGetCompressedTextureFormats":
            c.SetOutputWords(1, [0x8D64])   // GL_ETC1_RGB8_OES
        case "glGetShaderPrecisionFormat":
            let v = g.GetShaderPrecisionFormat(c.U32(0), c.U32(1))
            c.SetOutputWords(2, wordsOf([v[0], v[1]]))
            c.SetOutputWords(3, wordsOf([v[2]]))

        // MARK: buffers and vertex arrays
        case "glGenBuffers": c.SetOutputWords(1, g.GenBuffers(c.I32(0)))
        case "glDeleteBuffers": g.DeleteBuffers(c.Words(1))
        case "glBindBuffer": g.BindBuffer(c.U32(0), c.U32(1))
        case "glBufferData": g.BufferData(c.U32(0), size: int(c.I32(1)), data: c.Bytes(2), usage: c.U32(3))
        case "glBufferSubData": g.BufferSubData(c.U32(0), offset: int(c.I32(1)), data: c.Bytes(3))
        case "glIsBuffer": c.Return(uint32(g.IsBuffer(c.U32(0)) ? 1 : 0))
        case "glGetBufferParameteriv": c.SetOutputWords(2, wordsOf([g.GetBufferParameteri(c.U32(0), c.U32(1))]))
        case "glEnableVertexAttribArray": g.EnableVertexAttribArray(c.U32(0))
        case "glDisableVertexAttribArray": g.DisableVertexAttribArray(c.U32(0))
        case "glVertexAttribPointerData":
            // Tightly packed from the draw's first vertex.
            g.VertexAttribClientData(c.U32(0), size: c.I32(1), type: c.U32(2), normalized: c.Bool(3), integer: false, data: c.Bytes(5))
        case "glVertexAttribPointerOffset":
            g.VertexAttribPointer(c.U32(0), size: c.I32(1), type: c.U32(2), normalized: c.Bool(3), stride: c.I32(4), offset: uint64(c.U32(5)))
        case "glVertexAttrib1f": g.VertexAttrib(c.U32(0), [c.F32(1)])
        case "glVertexAttrib2f": g.VertexAttrib(c.U32(0), [c.F32(1), c.F32(2)])
        case "glVertexAttrib3f": g.VertexAttrib(c.U32(0), [c.F32(1), c.F32(2), c.F32(3)])
        case "glVertexAttrib4f": g.VertexAttrib(c.U32(0), [c.F32(1), c.F32(2), c.F32(3), c.F32(4)])
        case "glVertexAttrib1fv": g.VertexAttrib(c.U32(0), Array(c.Floats(1).prefix(1)))
        case "glVertexAttrib2fv": g.VertexAttrib(c.U32(0), Array(c.Floats(1).prefix(2)))
        case "glVertexAttrib3fv": g.VertexAttrib(c.U32(0), Array(c.Floats(1).prefix(3)))
        case "glVertexAttrib4fv": g.VertexAttrib(c.U32(0), Array(c.Floats(1).prefix(4)))
        case "glGetVertexAttribfv":
            if let v = g.GetVertexAttrib(c.U32(0), c.U32(1)) { c.SetOutputWords(2, v.Floats.map { $0.bitPattern }) }
        case "glGetVertexAttribiv":
            if let v = g.GetVertexAttrib(c.U32(0), c.U32(1)) { c.SetOutputWords(2, wordsOf(v.Ints)) }
        case "glGenVertexArraysOES", "glGenVertexArrays": c.SetOutputWords(1, g.GenVertexArrays(c.I32(0)))
        case "glDeleteVertexArraysOES", "glDeleteVertexArrays": g.DeleteVertexArrays(c.Words(1))
        case "glBindVertexArrayOES", "glBindVertexArray": g.BindVertexArray(c.U32(0))
        case "glIsVertexArrayOES", "glIsVertexArray": c.Return(uint32(g.IsVertexArray(c.U32(0)) ? 1 : 0))

        // MARK: drawing
        case "glClear": g.Clear(c.U32(0))
        case "glDrawArrays": g.DrawArrays(c.U32(0), c.I32(1), c.I32(2))
        case "glDrawElementsOffset": g.DrawElements(c.U32(0), c.I32(1), c.U32(2), offset: uint64(c.U32(3)))
        case "glDrawElementsData": g.DrawElementsClientData(c.U32(0), c.I32(1), c.U32(2), indices: c.Bytes(3))
        case "glReadPixels":
            c.SetOutput(6, g.ReadPixels(c.I32(0), c.I32(1), c.I32(2), c.I32(3), c.U32(4), c.U32(5)))

        // MARK: textures
        case "glGenTextures": c.SetOutputWords(1, g.GenTextures(c.I32(0)))
        case "glDeleteTextures": g.DeleteTextures(c.Words(1))
        case "glBindTexture": g.BindTexture(c.U32(0), c.U32(1))
        case "glIsTexture": c.Return(uint32(g.IsTexture(c.U32(0)) ? 1 : 0))
        case "glTexImage2D":
            g.TexImage2D(c.U32(0), level: c.I32(1), internalFormat: c.U32(2), width: c.I32(3), height: c.I32(4), border: c.I32(5),
                         format: c.U32(6), type: c.U32(7), data: c.Bytes(8))
        case "glTexSubImage2D":
            g.TexSubImage2D(c.U32(0), level: c.I32(1), x: c.I32(2), y: c.I32(3), width: c.I32(4), height: c.I32(5),
                            format: c.U32(6), type: c.U32(7), data: c.Bytes(8))
        case "glCompressedTexImage2D":
            g.CompressedTexImage2D(c.U32(0), level: c.I32(1), internalFormat: c.U32(2), width: c.I32(3), height: c.I32(4),
                                   border: c.I32(5), data: c.Bytes(7))
        case "glCompressedTexSubImage2D":
            g.CompressedTexSubImage2D(c.U32(0), level: c.I32(1), x: c.I32(2), y: c.I32(3), width: c.I32(4), height: c.I32(5),
                                      format: c.U32(6), data: c.Bytes(8))
        case "glCopyTexImage2D":
            g.CopyTexImage2D(c.U32(0), level: c.I32(1), internalFormat: c.U32(2), x: c.I32(3), y: c.I32(4),
                             width: c.I32(5), height: c.I32(6), border: c.I32(7))
        case "glCopyTexSubImage2D":
            g.CopyTexSubImage2D(c.U32(0), level: c.I32(1), xoffset: c.I32(2), yoffset: c.I32(3), x: c.I32(4), y: c.I32(5),
                                width: c.I32(6), height: c.I32(7))
        case "glTexParameteri": g.TexParameteri(c.U32(0), c.U32(1), c.I32(2))
        case "glTexParameterf": g.TexParameterf(c.U32(0), c.U32(1), c.F32(2))
        case "glTexParameteriv":
            if let v = c.Ints(2).first { g.TexParameteri(c.U32(0), c.U32(1), v) }
        case "glTexParameterfv":
            if let v = c.Floats(2).first { g.TexParameterf(c.U32(0), c.U32(1), v) }
        case "glGetTexParameteriv": c.SetOutputWords(2, wordsOf([g.GetTexParameteri(c.U32(0), c.U32(1))]))
        case "glGetTexParameterfv": c.SetOutputWords(2, [float32(g.GetTexParameteri(c.U32(0), c.U32(1))).bitPattern])
        case "glGenerateMipmap": g.GenerateMipmap(c.U32(0))

        // MARK: framebuffers
        case "glGenFramebuffers": c.SetOutputWords(1, g.GenFramebuffers(c.I32(0)))
        case "glDeleteFramebuffers": g.DeleteFramebuffers(c.Words(1))
        case "glBindFramebuffer": g.BindFramebuffer(c.U32(0), c.U32(1))
        case "glIsFramebuffer": c.Return(uint32(g.IsFramebuffer(c.U32(0)) ? 1 : 0))
        case "glFramebufferTexture2D": g.FramebufferTexture2D(c.U32(0), c.U32(1), c.U32(2), c.U32(3), c.I32(4))
        case "glFramebufferRenderbuffer": g.FramebufferRenderbuffer(c.U32(0), c.U32(1), c.U32(2), c.U32(3))
        case "glCheckFramebufferStatus": c.Return(g.CheckFramebufferStatus(c.U32(0)))
        case "glGetFramebufferAttachmentParameteriv":
            c.SetOutputWords(3, wordsOf([g.GetFramebufferAttachmentParameteri(c.U32(0), c.U32(1), c.U32(2))]))
        case "glGenRenderbuffers": c.SetOutputWords(1, g.GenRenderbuffers(c.I32(0)))
        case "glDeleteRenderbuffers": g.DeleteRenderbuffers(c.Words(1))
        case "glBindRenderbuffer": g.BindRenderbuffer(c.U32(0), c.U32(1))
        case "glIsRenderbuffer": c.Return(uint32(g.IsRenderbuffer(c.U32(0)) ? 1 : 0))
        case "glRenderbufferStorage": g.RenderbufferStorage(c.U32(0), c.U32(1), c.I32(2), c.I32(3))
        case "glGetRenderbufferParameteriv": c.SetOutputWords(2, wordsOf([g.GetRenderbufferParameteri(c.U32(0), c.U32(1))]))
        case "glDiscardFramebufferEXT": break

        // MARK: shaders and programs
        case "glCreateShader": c.Return(g.CreateShader(c.U32(0)))
        case "glShaderString": g.ShaderSource(c.U32(0), c.Text(1))
        case "glCompileShader": g.CompileShader(c.U32(0))
        case "glDeleteShader": g.DeleteShader(c.U32(0))
        case "glIsShader": c.Return(uint32(g.IsShader(c.U32(0)) ? 1 : 0))
        case "glGetShaderiv": c.SetOutputWords(2, wordsOf([g.GetShaderi(c.U32(0), c.U32(1))]))
        case "glGetShaderInfoLog":
            let s = cString(g.GetShaderInfoLog(c.U32(0)), size: int(c.I32(1)))
            c.SetOutputWords(2, [uint32(max(0, s.count - 1))])
            c.SetOutput(3, s)
        case "glGetShaderSource":
            let s = cString(g.GetShaderSource(c.U32(0)), size: int(c.I32(1)))
            c.SetOutputWords(2, [uint32(max(0, s.count - 1))])
            c.SetOutput(3, s)
        case "glCreateProgram": c.Return(g.CreateProgram())
        case "glAttachShader": g.AttachShader(c.U32(0), c.U32(1))
        case "glDetachShader": g.DetachShader(c.U32(0), c.U32(1))
        case "glBindAttribLocation": g.BindAttribLocation(c.U32(0), c.U32(1), c.Text(2))
        case "glLinkProgram": g.LinkProgram(c.U32(0))
        case "glUseProgram": g.UseProgram(c.U32(0))
        case "glDeleteProgram": g.DeleteProgram(c.U32(0))
        case "glIsProgram": c.Return(uint32(g.IsProgram(c.U32(0)) ? 1 : 0))
        case "glValidateProgram": g.ValidateProgram(c.U32(0))
        case "glGetProgramiv": c.SetOutputWords(2, wordsOf([g.GetProgrami(c.U32(0), c.U32(1))]))
        case "glGetProgramInfoLog":
            let s = cString(g.GetProgramInfoLog(c.U32(0)), size: int(c.I32(1)))
            c.SetOutputWords(2, [uint32(max(0, s.count - 1))])
            c.SetOutput(3, s)
        case "glGetAttachedShaders":
            let list = Array(g.GetAttachedShaders(c.U32(0)).prefix(max(0, int(c.I32(1)))))
            c.SetOutputWords(2, [uint32(list.count)])
            c.SetOutputWords(3, list)
        case "glGetActiveAttrib", "glGetActiveUniform":
            let v = c.Name == "glGetActiveAttrib" ? g.GetActiveAttrib(c.U32(0), c.U32(1)) : g.GetActiveUniform(c.U32(0), c.U32(1))
            if let a = v {
                let s = cString(a.Name, size: int(c.I32(2)))
                c.SetOutputWords(3, [uint32(max(0, s.count - 1))])
                c.SetOutputWords(4, [uint32(bitPattern: a.Size)])
                c.SetOutputWords(5, [a.Type])
                c.SetOutput(6, s)
            }
        case "glGetAttribLocation": c.Return(g.GetAttribLocation(c.U32(0), c.Text(1)))
        case "glGetUniformLocation": c.Return(g.GetUniformLocation(c.U32(0), c.Text(1)))
        case "glGetUniformfv", "glGetUniformiv": c.SetOutputWords(2, g.GetUniform(c.U32(0), c.I32(1)))
        case "glUniform1f": g.Uniformfv(c.I32(0), width: 1, count: 1, [c.F32(1)])
        case "glUniform2f": g.Uniformfv(c.I32(0), width: 2, count: 1, [c.F32(1), c.F32(2)])
        case "glUniform3f": g.Uniformfv(c.I32(0), width: 3, count: 1, [c.F32(1), c.F32(2), c.F32(3)])
        case "glUniform4f": g.Uniformfv(c.I32(0), width: 4, count: 1, [c.F32(1), c.F32(2), c.F32(3), c.F32(4)])
        case "glUniform1i": g.Uniformiv(c.I32(0), width: 1, count: 1, [c.I32(1)])
        case "glUniform2i": g.Uniformiv(c.I32(0), width: 2, count: 1, [c.I32(1), c.I32(2)])
        case "glUniform3i": g.Uniformiv(c.I32(0), width: 3, count: 1, [c.I32(1), c.I32(2), c.I32(3)])
        case "glUniform4i": g.Uniformiv(c.I32(0), width: 4, count: 1, [c.I32(1), c.I32(2), c.I32(3), c.I32(4)])
        case "glUniform1fv": g.Uniformfv(c.I32(0), width: 1, count: int(c.I32(1)), c.Floats(2))
        case "glUniform2fv": g.Uniformfv(c.I32(0), width: 2, count: int(c.I32(1)), c.Floats(2))
        case "glUniform3fv": g.Uniformfv(c.I32(0), width: 3, count: int(c.I32(1)), c.Floats(2))
        case "glUniform4fv": g.Uniformfv(c.I32(0), width: 4, count: int(c.I32(1)), c.Floats(2))
        case "glUniform1iv": g.Uniformiv(c.I32(0), width: 1, count: int(c.I32(1)), c.Ints(2))
        case "glUniform2iv": g.Uniformiv(c.I32(0), width: 2, count: int(c.I32(1)), c.Ints(2))
        case "glUniform3iv": g.Uniformiv(c.I32(0), width: 3, count: int(c.I32(1)), c.Ints(2))
        case "glUniform4iv": g.Uniformiv(c.I32(0), width: 4, count: int(c.I32(1)), c.Ints(2))
        case "glUniformMatrix2fv": g.UniformMatrixfv(c.I32(0), size: 2, count: int(c.I32(1)), transpose: c.Bool(2), c.Floats(3))
        case "glUniformMatrix3fv": g.UniformMatrixfv(c.I32(0), size: 3, count: int(c.I32(1)), transpose: c.Bool(2), c.Floats(3))
        case "glUniformMatrix4fv": g.UniformMatrixfv(c.I32(0), size: 4, count: int(c.I32(1)), transpose: c.Bool(2), c.Floats(3))
        case "glReleaseShaderCompiler": break
        default:
            renderer.note(c.Name)
        }
    }
}
