# vm/disk/vhdx

Reads and writes VHDX images: the format Hyper-V uses, and the one Windows images and Windows' own tools produce.

```vertex
import "vm/disk/vhdx"
```

## Types

- **`Metadata`** (struct): The parts of the metadata region this package needs.
- **`Image`** (class): An open VHDX image.

## Functions

- `func Open(_ file: fs.File, readOnly: bool = false) throws -> Image`: Opens a VHDX image.
- `func Create(_ path: fs.Path, size: uint64, blockSize: uint32 = 32 << 20) throws -> Image`: Creates a dynamic VHDX of `size` bytes.

Part of the [`vm`](https://github.com/vertex-language/vm) repository.
