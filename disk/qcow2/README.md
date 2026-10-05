# vm/disk/qcow2

Reads and writes QCOW2 images (versions 2 and 3): sparse, copy-on-write, with an optional read-only backing image. Writes allocate clusters at the end of the file with 16-bit refcounts, write data before the L2 entry before the L1 entry, and copy the untouched part of a cluster up from a compressed cluster or the backing image. `qemu-img check` finds the images clean (`cmd/check`).

```vertex
import "vm/disk/qcow2"
```

## Types

- **`Header`** (struct): The QCOW2 header: the fields of version 2, and the version 3 extras.
- **`Image`** (class): An open QCOW2 image.

## Functions

- `func ParseHeader(_ b: [uint8]) throws -> Header`: Parses a header from the first bytes of an image.
- `func Create(_ path: fs.Path, size: uint64, clusterBits: uint32 = 16, backing: string? = nil, openBacking: ((string) throws -> any disk.Image)? = nil) throws -> Image`: Makes a version 3 image, every cluster unallocated (a copy-on-write overlay of `backing`, if named), open for writing.
- `Image.WriteCompressed(_ offset: uint64, _ cluster: [uint8]) throws`: Writes one whole cluster deflated, packed with the others, as `qemu-img convert -c` does.
- `func Open(_ file: fs.File, readOnly: bool = false, openBacking: ((string) throws -> any disk.Image)? = nil) throws -> Image`: Opens a QCOW2 image.

Part of the [`vm`](https://github.com/vertex-language/vm) repository.
