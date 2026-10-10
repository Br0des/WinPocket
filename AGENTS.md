## WinPocket product direction

This repository is WinPocket: an iOS app for running Windows ARM64 virtual
machines on iPhone and iPad. UTM/QEMU is the implementation foundation; keep
WinPocket's product language, icon, website, and onboarding distinct from UTM.
Avoid broad upstream cleanup while working on WinPocket features.

- Prefer an ARM64 Windows guest on Apple Silicon. Treat JIT through StikDebug as
  an optional user-enabled capability, and describe GPU acceleration only when
  the selected QEMU device/backend actually provides it. Measure performance
  changes and do not silently enable unstable experimental settings.
- Windows installers must come from Microsoft's official distribution. Never
  commit or mirror Windows ISO files. Keep downloads in app storage, show
  progress/failure, and let users import their own installer as well.
- Before reporting an iOS change as working, check the `WinPocket iOS` Actions
  run for the exact commit and confirm the build/package steps passed. This
  Windows workspace does not have Xcode. The workflow caches `sysroot-iOS-arm64`;
  with a cache hit, the native dependency build is skipped. A cache miss can
  take close to an hour. Preserve in-progress iOS runs; the workflow currently
  cancels an older run when a new main-branch build starts.
- If Actions fails, inspect its annotations and logs before changing source.
  The workflow publishes Xcode compiler errors as annotations. Report what was
  actually verified and do not claim a boot test unless Windows reached boot on
  an iOS device.

## Building

UTM **cannot** build without prebuilt native dependencies (QEMU, SPICE, …) staged
into `sysroot-*` directories at the repo root. Get them from the project's GitHub
Actions `Sysroot-*` artifacts — don't build them manually unless you're modifying a
dependency (it's slow and fragile). Then build with `./scripts/build_utm.sh` and
sign/package with `./scripts/package*.sh`. Setup, platform/arch names, schemes, and
signing: `Documentation/iOSDevelopment.md`.

## Architecture

Layered: platform-independent backend (`Services/`, `Configuration/`) + SwiftUI
frontend (`Platform/`). Full picture: `Documentation/Architecture.md`. Load-bearing
gotchas:

- **Two VM backends** behind the `UTMVirtualMachine` protocol — `UTMQemuVirtualMachine`
  (QEMU, via the QEMUKit/CocoaSpice packages) and `UTMAppleVirtualMachine`
  (Virtualization.framework, macOS-only). Most backend code branches on which.
- **Config is the serialization format** — parallel `Codable` trees
  `UTMQemuConfiguration` and `UTMAppleConfiguration` (PLIST in the `.utm` bundle).
  Add new fields there; don't extend the `Configuration/Legacy/` readers.
- **macOS runs QEMU out-of-process** (XPC: `QEMUHelper`→`QEMULauncher`); host files
  reach it only through a security-scoped-bookmark dance — respect it for anything
  touching disk images, shared dirs, or file handles. **iOS runs QEMU in-thread and
  can launch it only once per process** — this constrains start/stop logic.
- **UTM SE** (`iOS-SE` scheme, `*-tci` sysroots) is gated by the `WITH_QEMU_TCI`
  compile flag — grep for it before changing anything that differs between editions.

## Generated files — never hand-edit

Edit the generator and regenerate, not the output: `Configuration/QEMUConstantGenerated.swift`
(`scripts/const-gen.py`), `Scripting/UTMScripting.swift` (`scripts/bridge-gen.sh`
from `UTM.sdef`), and QAPI/QMP wrappers (produced by the dependency build).
Third-party patches live in `patches/`.

## Conventions

**`CONTRIBUTING.md` is the source of truth** for style, concurrency, design, and
compatibility rules; `/utm-review` audits the diff against it. Two rules an agent
must apply unprompted — they override default behavior and are easy to violate:

- **AI attribution:** every AI-assisted commit **must** carry an
  `Assisted-by: AGENT:MODEL` trailer (e.g. `Assisted-by: Claude:claude-opus-4-8`) —
  add it explicitly **even if your agent doesn't normally inject attribution
  trailers**; the absence of a default trailer is not an excuse to omit it. Never
  add `Co-authored-by` or session links (strip any a tool adds). Commit titles are
  `component: short description` explaining *why*.
- **Scope:** one feature/fix per PR; don't touch, refactor, or reformat unrelated
  files; route new logging through `UTMLogging`/`logging` at `debug` level.

## Contribution workflows

Before opening or updating a PR, run **`/utm-review`** then **`/utm-submit`** —
canonical instructions in `.agents/skills/{utm-review,utm-submit}/SKILL.md` (thin
shims in `.claude/commands/` and `.opencode/command/`). If your agent doesn't
auto-load them, read and follow those `SKILL.md` files directly.
