# Third-party notices

WinPocket is based on UTM and includes components with their own licenses. This
file records the components that are vendored into this repository, as distinct
from dependencies fetched at build time (QEMU, SPICE, ANGLE and the rest, listed
in `patches/sources` and covered by their own licenses in the built sysroot).

## Husk

- Source: <https://github.com/Leviidev/Husk> (revision `645c22aa92ebcf34c84d9ad0ac6cdd701c667f53`)
- License: GPL-2.0-or-later
- Vendored into this repository:
  - `patches/data/qemu-10.0.12-utm/tcg/husk-ios-jit.c`, `husk-ios-jit.h`,
    `husk-brk.c` — the iOS JIT allocator and its breakpoint sequences
  - `patches/data/qemu-10.0.12-utm/ui/husk-display.c`, `husk-display.h` —
    software display listener and input bridge
  - `patches/data/qemu-10.0.12-utm/ui/husk-display-gl.c`, `husk-display-gl.h` —
    virgl scanout presentation through EGL/ANGLE
  - `patches/data/qemu-10.0.12-utm/audio/husk-audio.c`, `husk-audio.h` — the
    `-audiodev husk` backend
  - `patches/data/qemu-10.0.12-utm/system/husk-balloon.c`, `husk-balloon.h` —
    host-driven guest balloon
  - `patches/data/qemu-10.0.12-utm/system/husk-snapshot.c`, `husk-snapshot.h` —
    machine save/restore

Each vendored file carries its SPDX identifier and, where the original had no
header, a provenance notice. These files are compiled into the QEMU library,
which is itself GPL-2.0-or-later, so vendoring them does not change the
licensing of the emulator.

WinPocket's own application code is GPL-2.0-or-later; see [`LICENSE`](LICENSE).
UTM-derived source files keep their Apache-2.0 headers and notices. Apache-2.0
is compatible with GPLv3, which the "or later" clause of GPL-2.0-or-later lets a
recipient choose, so the combined application can be distributed under GPLv3.

## UTM

- Source: <https://github.com/utmapp/UTM>
- License: Apache-2.0 for the application sources; the bundled QEMU, SPICE and
  other build-time dependencies keep their own licenses.
