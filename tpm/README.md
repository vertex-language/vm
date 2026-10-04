# vm/tpm

A TPM 2.0 for guests: a TIS register interface (`Tis`, TCG PC Client Platform TPM Profile, FIFO interface) that firmware and operating systems drive with their own drivers, in front of a `Backend` that executes TPM 2.0 commands.

```vertex
import "vm/tpm"
```

## Types

- **`Backend`** (protocol): Executes TPM 2.0 commands. `Tis` calls one method at a time.
- **`TpmError`** (enum)
- **`Swtpm`** (class): swtpm, the TPM 2.0 emulator over libtpms, as a child process: its data channel takes commands, its control channel powers it on and sets the locality (swtpm's ioctl protocol, `tpm_ioctl.h`).
- **`Tis`** (class): A TPM's TIS / FIFO register interface over MMIO, 5 KiB per locality times 5 (`Size`).

## Functions

- `func FailureResponse() -> [uint8]`: A response saying the TPM failed (TPM_RC_FAILURE): what the guest gets when the backend can't be reached, rather than a TPM that never answers.

Part of the [`vm`](https://github.com/vertex-language/vm) repository.
