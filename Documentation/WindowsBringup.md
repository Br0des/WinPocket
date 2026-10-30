# Windows ARM bring-up

WinPocket targets Windows 11 ARM64 as a QEMU guest on iOS. A successful IPA build does not establish that Windows boots or that its guest can use accelerated graphics.

## Backend comparison

[Husk](https://github.com/Leviidev/Husk) uses the same `qemu-10.0.12-utm` source release as WinPocket, running QEMU's ARM64 system emulator in the app process. Its [JIT allocator and QEMU patch](https://github.com/Leviidev/Husk/tree/645c22aa92ebcf34c84d9ad0ac6cdd701c667f53/src/ios-jit) are relevant to an ARM64 Windows guest as well as an Android guest: they change how the iOS **host** obtains executable memory for QEMU's TCG, not the guest operating system.

Husk's [architecture notes](https://github.com/Leviidev/Husk/blob/645c22aa92ebcf34c84d9ad0ac6cdd701c667f53/docs/00-architecture.md) report an on-device JIT allocation and execution self-test, but do not establish a Windows boot. Its separate display bridge and Android guest configuration are not a Windows 3D driver. WinPocket already has QEMU's ARM `virt` machine, UEFI, TPM, NVMe, SPICE and an experimental DirectX backend; replacing these with Husk's Android-specific setup would require restoring and retesting each Windows dependency.

## JIT integration requirements

The existing StikDebug URL handoff is not the complete executable-memory protocol required on devices with TXM/SPTM. A possible integration of Husk's approach needs all of the following, tested together:

1. Build the allocator, breakpoint assembly and [TCG region patch](https://github.com/Leviidev/Husk/blob/645c22aa92ebcf34c84d9ad0ac6cdd701c667f53/patches/husk-qemu-ios-jit.patch) into the iOS QEMU library; preserve non-iOS and interpreter builds. Export the coordination symbols needed by the app and update the Actions dependency-cache key.
2. Coordinate StikDebug's script and a prepared RX/RW mapping before the debugger detaches. Do not issue an unhandled breakpoint. A debugger flag or accepted URL is not proof that generated code can execute; perform an execution self-test.
3. Match the preallocated size to the actual VM's `tb-size`, handle allocation and initialization errors, and retain the mapping for QEMU's lifetime. Account for app suspension, failed attach, repeated attempts, and QEMU's one-launch-per-process restriction on iOS.
4. Keep the existing non-TXM JIT path functional. Test both paths on representative devices, as well as missing debugger, unsupported signing and memory-pressure cases.
5. Review licensing and attribution before distributing adapted code. Husk labels its allocator GPL-2.0-or-later and documents its own [licensing analysis](https://github.com/Leviidev/Husk/blob/645c22aa92ebcf34c84d9ad0ac6cdd701c667f53/docs/01-licensing.md); WinPocket retains Apache-2.0 app source alongside QEMU components. Do not assume the distribution implications of combining them have been resolved.

This is an integration plan, not a claim that Husk's allocator is already wired into WinPocket. Do not copy its Android snapshot workaround into Windows: the stated safety condition depends on Android-specific guest behavior.

### JIT 1 status: allocator source integrated into the QEMU build

Requirement 1 is implemented in this tree (2026-10-30, `qemu-10.0.12-utm`):

- `patches/data/qemu-10.0.12-utm/tcg/` vendors the Husk allocator
  (`husk-ios-jit.c`, `husk-ios-jit.h`) and a C translation of its break
  sequences (`husk-brk.c`, replacing `husk-brk.S` so meson handles them as plain
  C with fixed-register inline assembly). Each file carries its provenance
  header (Husk `src/ios-jit`, GPL-2.0-or-later) — see requirement 5, which
  remains open.
- `scripts/husk-jit-integrate.py <qemu-tree> <repo-root>` wires them into an
  unpacked QEMU tree: appends the include/hook to `tcg/region.c` (a guarded
  `alloc_code_gen_buffer_splitwx_husk_ios` that tries the debugger-serviced
  dual mapping first and falls back to the vmremap path on failure), adds the
  two sources to `tcg/meson.build`, and appends the 13 app-facing
  `husk_ios_*` symbols to `system/qemu.symbols`. It is idempotent, CRLF-aware,
  refuses to touch a file it does not recognize, and hard-verifies its own
  edits. Interpreter and non-Apple builds compile without the husk code.
- `scripts/build_dependencies.sh` calls the integrator after
  `build_qemu_dependencies` and before QEMU's configure, so both fresh and
  `-rebuild` runs get it; a `download()` already stages the vendored sources
  from `patches/data/` when it unpacks QEMU.
- Verified locally against a fixture tree built from the pinned upstream
  `region.c`, `tcg/meson.build` and `system/qemu.symbols` (first pass,
  idempotence, guard placement), and the vendored sources pass `clang
  -fsyntax-only` on the non-iOS stub branch.

Not yet done: requirements 2–4 (app-side StikDebug coordination, prewarm strategy,
and device testing) and the Actions dependency-cache-key update on the next
sysroot rebuild. None of this asserts a successful Windows boot; the acceptance
checks below still govern any such claim.

### Integration findings

- The pinned Husk `region.c` patch applies in a dry run to the corresponding UTM QEMU release source. This does **not** test compilation or the rest of Husk's integration script, which also changes the build and export lists.
- WinPocket loads the target QEMU framework only when starting the VM. The preparation path must instead load and retain the same framework before StikDebug detaches; otherwise the prewarmed mapping and its state will not be available to QEMU.
- WinPocket's TCG cache is currently the configured `jitCacheSize`, or one quarter of guest RAM if unset. A 4 GiB guest therefore requests a 1 GiB cache by default, not Husk's 256 MiB QEMU cache or 512 MiB prewarm. Size the region for the actual configuration and account for memory and debugger page-preparation costs rather than copying those constants.
- Husk's pinned implementation sets `g_jit_available` before its generated-code self-test. Its readiness flag is therefore not sufficient evidence of a passing test on its own. Its prewarm failure is also one-shot, so retry and process-restart behavior need an explicit design.
- Do not assume `CS_DEBUGGED` means the correct script is servicing traps: the flag may persist after a debugger detaches, and a different debugger can stop the process on a breakpoint without handling it. The [StikJIT integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md) describes the universal breakpoint protocol and requires preparation before detach. Preserve older devices' existing JIT behavior rather than automatically issuing traps to arbitrary debuggers.
- Husk's bundled script has no clear license header at the pinned revision. Its provenance, and the distribution implications of combining the GPL-licensed allocator with WinPocket's existing components, require review before redistribution; this is not a legal conclusion.

## Acceptance checks

- Build and package the exact commit in the `WinPocket iOS` Actions workflow. Install a correctly signed build on an identified iPhone or iPad and record its model, iOS version, installation method and available memory.
- Establish that the selected JIT path can execute generated code and that QEMU starts. Obtain a Windows 11 ARM64 ISO from Microsoft or import a user-provided installer; do not bundle or mirror the image.
- Observe Windows Setup on the actual device, complete installation to a usable Windows desktop, shut down and restart from the virtual disk. Record any installer, network, storage, TPM, memory or input failures.
- Test graphics independently. On iOS 16 or later, the existing experimental DirectX 11 path requires a compatible accelerated display, the default or ANGLE (Metal) renderer, DirectX enabled, and the experimental driver from Windows guest tools. Verify a guest DirectX workload and report failures; a Metal-rendered framebuffer alone is not guest GPU acceleration. See [Windows guest tools](https://docs.getutm.app/guest-support/windows/).
- Keep experimental settings opt-in, retain a usable non-accelerated display fallback, and measure performance on the device before making performance claims.
