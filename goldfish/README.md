# vm/goldfish

The Android emulator's "ranchu" board devices, which goldfish kernels drive.

```vertex
import "vm/goldfish"
```

## Types

- **`Pipe`** (class): The pipe device (`generic,android-pipe`), version 2 of its protocol: guest processes open `/dev/qemu_pipe` and write `pipe:<service>[:<args>]`, then talk to that host service over a byte stream. A command page per pipe, a signal buffer for wakes, one interrupt. `Register(name, service)`; `Refused` lists what a guest asked for that no service answered.
- **`PipeService`** (protocol): A host service: `Open(args, waker:)` makes a connection, or refuses one.
- **`PipeConnection`** (protocol): One guest connection: `Send` takes bytes (or says `.again`), `Receive` hands bytes over, `Readable`/`Writable`/`Closed`, `Close`.
- **`Waker`** (class): Lets a connection wake a guest waiting on it: `Readable()`, `Writable()`, `Closed()`.
- **`Transfer`** (enum), **`PollFlags`** (struct): A read or write's outcome; what a poll reports.
- **`QemudService`** (protocol), **`QemudPipe`** (class), **`QemudClient`** (class): qemud's small services over the pipe: messages framed by four hex digits of length; `Reply(_:)` answers.
- **`Fb`** (class): The framebuffer (`generic,goldfish-fb`): RGB565 in guest RAM, flipped by SET_BASE.
- **`Events`** (class): The input device (`generic,goldfish-events-keypad`), called `qwerty2`: a touchscreen and keyboard.
- **`Battery`** (class): The battery (`generic,goldfish-battery`), always full on mains.

The pipe's behavior follows the kernel's `goldfish_pipe_v2.c` and the emulator's `hw/misc/goldfish_pipe.c` (statuses: bytes moved, 0 at end-of-file, PIPE_ERROR_AGAIN to wait; a wake asked for after the data arrived is signalled at once). `cmd/check` drives it as the driver does.

Part of the [`vm`](../README.md) repository.
