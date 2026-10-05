package gfxstream

import (
    "gles/fixed"
)

/// GLfixed (16.16) to float.
func fx(_ v: uint32) -> float32 { float32(int32(bitPattern: v)) / 65536 }

extension RenderConnection {
    /// A GLES 1.1 call, for the current 1.1 context.
    func gles1(_ c: Call, _ f: fixed.Context) {
        let g = f.GL
        switch c.Name {
        // MARK: capabilities and state that 1.1 keeps itself
        case "glEnable": f.Enable(c.U32(0))
        case "glDisable": f.Disable(c.U32(0))
        case "glIsEnabled": c.Return(uint32(f.IsEnabled(c.U32(0)) ? 1 : 0))
        case "glActiveTexture": f.ActiveTexture(c.U32(0))
        case "glClientActiveTexture": f.ClientActiveTexture(c.U32(0))
        case "glAlphaFunc": f.AlphaFunc(c.U32(0), c.F32(1))
        case "glAlphaFuncx": f.AlphaFunc(c.U32(0), fx(c.U32(1)))
        case "glShadeModel": f.ShadeModel(c.U32(0))
        case "glColor4f": f.Color(c.F32(0), c.F32(1), c.F32(2), c.F32(3))
        case "glColor4x": f.Color(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)))
        case "glColor4ub": f.Color(float32(c.U32(0)) / 255, float32(c.U32(1)) / 255, float32(c.U32(2)) / 255, float32(c.U32(3)) / 255)
        case "glNormal3f": f.Normal(c.F32(0), c.F32(1), c.F32(2))
        case "glNormal3x": f.Normal(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)))
        case "glMultiTexCoord4f": f.MultiTexCoord(c.U32(0), [c.F32(1), c.F32(2), c.F32(3), c.F32(4)])
        case "glMultiTexCoord4x": f.MultiTexCoord(c.U32(0), [fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)), fx(c.U32(4))])
        case "glPointSize": f.PointSize(c.F32(0))
        case "glPointSizex": f.PointSize(fx(c.U32(0)))

        // MARK: fixed-point forms of shared state
        case "glClearColorx": g.ClearColor(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)))
        case "glClearDepthx": g.ClearDepthf(fx(c.U32(0)))
        case "glDepthRangex": g.DepthRangef(fx(c.U32(0)), fx(c.U32(1)))
        case "glLineWidthx": g.LineWidth(fx(c.U32(0)))
        case "glPolygonOffsetx": g.PolygonOffset(fx(c.U32(0)), fx(c.U32(1)))
        case "glSampleCoveragex": g.SampleCoverage(fx(c.U32(0)), c.Bool(1))

        // MARK: matrices
        case "glMatrixMode": f.MatrixMode(c.U32(0))
        case "glLoadIdentity": f.LoadIdentity()
        case "glLoadMatrixf": f.LoadMatrix(fixed.Mat4(c.Floats(0)))
        case "glLoadMatrixx": f.LoadMatrix(fixed.Mat4(c.Words(0).map { fx($0) }))
        case "glMultMatrixf": f.MultMatrix(fixed.Mat4(c.Floats(0)))
        case "glMultMatrixx": f.MultMatrix(fixed.Mat4(c.Words(0).map { fx($0) }))
        case "glPushMatrix": f.PushMatrix()
        case "glPopMatrix": f.PopMatrix()
        case "glTranslatef": f.Translate(c.F32(0), c.F32(1), c.F32(2))
        case "glTranslatex": f.Translate(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)))
        case "glScalef": f.Scale(c.F32(0), c.F32(1), c.F32(2))
        case "glScalex": f.Scale(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)))
        case "glRotatef": f.Rotate(c.F32(0), c.F32(1), c.F32(2), c.F32(3))
        case "glRotatex": f.Rotate(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)))
        case "glOrthof": f.Ortho(c.F32(0), c.F32(1), c.F32(2), c.F32(3), c.F32(4), c.F32(5))
        case "glOrthox": f.Ortho(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)), fx(c.U32(4)), fx(c.U32(5)))
        case "glFrustumf": f.Frustum(c.F32(0), c.F32(1), c.F32(2), c.F32(3), c.F32(4), c.F32(5))
        case "glFrustumx": f.Frustum(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)), fx(c.U32(4)), fx(c.U32(5)))

        // MARK: texture environments and parameters
        case "glTexEnvf": f.TexEnv(c.U32(0), c.U32(1), [c.F32(2)])
        case "glTexEnvi": f.TexEnv(c.U32(0), c.U32(1), [float32(c.I32(2))])
        case "glTexEnvx":
            // An enum value (the mode) travels as itself, not as 16.16.
            f.TexEnv(c.U32(0), c.U32(1), [c.U32(1) == 0x2200 ? float32(c.U32(2)) : fx(c.U32(2))])
        case "glTexEnvfv": f.TexEnv(c.U32(0), c.U32(1), c.Floats(2))
        case "glTexEnviv": f.TexEnv(c.U32(0), c.U32(1), c.Ints(2).map { c.U32(1) == 0x2201 ? float32($0) / 2147483647 : float32($0) })
        case "glTexEnvxv": f.TexEnv(c.U32(0), c.U32(1), c.Words(2).map { c.U32(1) == 0x2200 ? float32($0) : fx($0) })
        case "glTexParameterx": g.TexParameteri(c.U32(0), c.U32(1), c.I32(2))   // enum values, as themselves
        case "glTexParameteriv", "glTexParameterxv": f.TexParameteriv(c.U32(0), c.U32(1), c.Ints(2))
        case "glTexParameterfv":
            f.TexParameteriv(c.U32(0), c.U32(1), c.Floats(2).map { int32($0) })

        // MARK: arrays
        case "glEnableClientState": f.EnableClientState(c.U32(0))
        case "glDisableClientState": f.DisableClientState(c.U32(0))
        case "glVertexPointerData": f.PointerData(0x8074, size: c.I32(0), type: c.U32(1), data: c.Bytes(3))
        case "glColorPointerData": f.PointerData(0x8076, size: c.I32(0), type: c.U32(1), data: c.Bytes(3))
        case "glNormalPointerData": f.PointerData(0x8075, size: 3, type: c.U32(0), data: c.Bytes(2))
        case "glTexCoordPointerData": f.PointerData(0x8078, unit: int(c.I32(0)), size: c.I32(1), type: c.U32(2), data: c.Bytes(4))
        case "glPointSizePointerData": f.PointerData(0x8B9C, size: 1, type: c.U32(0), data: c.Bytes(2))
        case "glVertexPointerOffset": f.Pointer(0x8074, size: c.I32(0), type: c.U32(1), stride: c.I32(2), offset: uint64(c.U32(3)))
        case "glColorPointerOffset": f.Pointer(0x8076, size: c.I32(0), type: c.U32(1), stride: c.I32(2), offset: uint64(c.U32(3)))
        case "glNormalPointerOffset": f.Pointer(0x8075, size: 3, type: c.U32(0), stride: c.I32(1), offset: uint64(c.U32(2)))
        case "glTexCoordPointerOffset": f.Pointer(0x8078, size: c.I32(0), type: c.U32(1), stride: c.I32(2), offset: uint64(c.U32(3)))
        case "glPointSizePointerOffset": f.Pointer(0x8B9C, size: 1, type: c.U32(0), stride: c.I32(1), offset: uint64(c.U32(2)))

        // MARK: drawing
        case "glDrawArrays": f.DrawArrays(c.U32(0), c.I32(1), c.I32(2))
        case "glDrawElementsOffset": f.DrawElements(c.U32(0), c.I32(1), c.U32(2), offset: uint64(c.U32(3)))
        case "glDrawElementsData": f.DrawElementsClientData(c.U32(0), c.I32(1), c.U32(2), indices: c.Bytes(3))
        case "glDrawTexiOES": f.DrawTex(float32(c.I32(0)), float32(c.I32(1)), float32(c.I32(2)), float32(c.I32(3)), float32(c.I32(4)))
        case "glDrawTexsOES":
            func s16(_ v: uint32) -> float32 { float32(int16(truncatingIfNeeded: v)) }
            f.DrawTex(s16(c.U32(0)), s16(c.U32(1)), s16(c.U32(2)), s16(c.U32(3)), s16(c.U32(4)))
        case "glDrawTexxOES": f.DrawTex(fx(c.U32(0)), fx(c.U32(1)), fx(c.U32(2)), fx(c.U32(3)), fx(c.U32(4)))
        case "glDrawTexfOES": f.DrawTex(c.F32(0), c.F32(1), c.F32(2), c.F32(3), c.F32(4))

        // MARK: what 1.1 adds that isn't modelled yet
        case "glLightf", "glLightfv", "glLightx", "glLightxv", "glLightModelf", "glLightModelfv", "glLightModelx", "glLightModelxv",
             "glMaterialf", "glMaterialfv", "glMaterialx", "glMaterialxv", "glFogf", "glFogfv", "glFogx", "glFogxv",
             "glClipPlanef", "glClipPlanex", "glPointParameterf", "glPointParameterfv", "glPointParameterx", "glPointParameterxv",
             "glLogicOp":
            renderer.note(c.Name)
        default:
            // The rest share GLES 2's signatures and meaning.
            gles2(c, g)
        }
    }
}
