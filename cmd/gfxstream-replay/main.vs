// gfxstream-replay runs a render stream recorded by `vm-run --gles-record
// <dir>` (dir/opengles.rec) through vm/gfxstream again, with no guest,
// and writes the frames the guest posted as PNGs.
//
//     vsc run gfxstream-replay -- dir/opengles.rec out-dir [width height] [--all] [--cpu]
//
// Only the last frame is written unless --all is given. It draws on the
// GPU when there is one, unless --cpu is given.
package main

import (
    "fs"
    "image"
    "image/png"
    "os/process"
    "vm/gfxstream"
)

func main() -> int32 {
    let args = process.Args
    if args.count < 3 {
        print("usage: gfxstream-replay recording out-dir [width height]")
        return 2
    }
    guard let data = try? fs.ReadFile(fs.Path(args[1])) else {
        print("can't read \(args[1])")
        return 1
    }
    let w = args.count > 4 ? int(args[3]) ?? 720 : 720
    let h = args.count > 4 ? int(args[4]) ?? 1280 : 1280   // --all, if given, comes last
    let r = gfxstream.Renderer(width: w, height: h, dpi: 320)
    r.DebugErrors = true
    let all = args.contains("--all")
    if !args.contains("--cpu") && r.UseGPU() { print("drawing on the GPU") }
    var frames = 0
    var last: [uint8] = []
    var lw = 0
    var lh = 0
    r.OnPost = { pixels, fw, fh in
        frames += 1
        if all {
            let img = image.RGBA(width: fw, height: fh, pixels: pixels)
            try? fs.WriteFile(fs.Path(args[2] + "/frame-\(frames).png"), png.Encode(img))
        } else {
            last = pixels
            lw = fw
            lh = fh
        }
    }
    let n = gfxstream.Replay(data, into: r)
    if !all && frames > 0 {
        try? fs.WriteFile(fs.Path(args[2] + "/last.png"), png.Encode(image.RGBA(width: lw, height: lh, pixels: last)))
    }
    print("replayed \(n) pieces, \(frames) frames posted")
    let top = r.Unimplemented.prefix(20).map { "\($0.0)×\($0.1)" }
    if !top.isEmpty { print("not carried out: \(top.joined(separator: ", "))") }
    if !r.Errors.isEmpty { print("errors: \(r.Errors.prefix(5))") }
    let g = r.GPUStats
    print("GPU: \(g.Draws) draws, \(g.Clears) clears, \(g.Uploads) uploads, \(g.Readbacks) readbacks, \(g.Fallbacks) on the CPU \(g.LastFailure)")
    return 0
}
