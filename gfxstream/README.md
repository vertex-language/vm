# vm/gfxstream

The host side of the Android emulator's render protocol: what a guest's EGL and GLES libraries write to the `opengles` pipe instead of drawing. vm is that host GPU.

```vertex
import "vm/gfxstream"
```

Each call is a packet: opcode, size, then its parameters, values inline and buffers as a length and bytes; outputs and a result come back. The calls come from the protocol's own spec files (`spec/`, from Google's gfxstream), turned into `signatures.vs` by `vsc run gen-gfxstream`, so the decoder is a table, not hand-written parsing.

- **renderControl** (the emulator's EGL): configs, contexts, window surfaces, **color buffers** (gralloc's buffers, `raster.Texture`s, top row first), `rcFBPost` (the screen), EGL images bound as textures.
- **GLES 1.1**: carried out by a [`gles/fixed`](../../gles/fixed) context for each 1.1 guest context (the boot animation).
- **GLES 2**: carried out by a [`gles`](../../gles) context per guest context; shaders compile with [`shader`](../../shader); draws rasterize with [`gpu/raster`](../../gpu).
- One renderer lock: every connection's calls run one at a time, as on one GPU.

## Types

- **`Renderer`** (class): The `opengles` pipe service, holding what all guest processes share. `OnPost` gets each posted frame (RGBA, top row first, opaque). `RecordDir` keeps the stream; `Unimplemented` and `Errors` say what it couldn't follow; `Connect()` is an in-process connection for tests and tools.
- **`RenderConnection`** (class): One guest render thread's stream.
- **`Decoder`** (class), **`Call`** (class), **`Signature`** (struct), **`ParamKind`**, **`Arg`** (enums): The protocol's packets, decoded.
- **`ColorBuffer`** (class): A gralloc buffer.
- **`Recording`** (class), **`Replay(_:into:)`** (func): A stream as it came, every connection's pieces in order, and running it again without a guest.

## Tools

- `vsc run gen-gfxstream`: regenerate `signatures.vs` from `spec/`.
- `vsc run gfxstream-replay -- rec out-dir [--all]`: replay `vm-run --gles-record`'s recording and write the posted frames as PNGs.

Not yet: GLES 3, 1.1's lighting and fog, checksums, DMA and async swap (none of which vm advertises, so guests don't use them).

Part of the [`vm`](../README.md) repository.
