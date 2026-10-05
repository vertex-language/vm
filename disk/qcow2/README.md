# vm/disk/qcow2

Reads and writes QCOW2 images (versions 2 and 3): sparse, copy-on-write, with an optional read-only backing image.

```vertex
import "vm/disk/qcow2"
```

## Types

- **`Header`** (struct): The QCOW2 header: the fields of version 2, and the version 3 extras.
- **`Image`** (class): An open QCOW2 image.

## Functions

- `func ParseHeader(_ b: [uint8]) throws -> Header`: Parses a header from the first bytes of an image.
- `func Open(_ file: fs.File, readOnly: bool = false, openBacking: ((string) throws -> any disk.Image)? = nil) throws -> Image`: Opens a QCOW2 image.

Part of the [`vm`](https://github.com/vertex-language/vm) repository.
