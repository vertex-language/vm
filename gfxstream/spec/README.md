# gfxstream/spec

The render protocol's call list, from Google's gfxstream
(https://android.googlesource.com/platform/hardware/google/gfxstream,
`codegen/{renderControl,gles1,gles2}` on `main`, October 2026), Apache
License 2.0. The emulator's guest encoders are generated from these files
by its `emugen` tool.

`vm/cmd/gen-gfxstream` reads them and writes `../signatures.vs`:

- **`.in`**: each call's C signature, one per line. A call's opcode is
  the `base_opcode` in `.attrib` plus the call's position in the file.
  Calls are only ever appended, so the newest files number every older
  guest's calls correctly: the Android 8.0 encoder headers
  (`renderControl_opcodes.h`, `gl2_opcodes.h` and `gl_opcodes.h` in
  goldfish-opengl's `oreo-release`) agree on every opcode.
- **`.attrib`**: per call, which pointer parameters are outputs (`dir
  out`) or both (`dir inout`); every other pointer is an input.
- **`.types`**: each type's width in bits.
