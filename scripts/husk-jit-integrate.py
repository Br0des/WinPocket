#!/usr/bin/env python3
# WinPocket: integrate the Husk iOS JIT allocator into an unpacked QEMU tree.
#
# Implements JIT integration requirement 1 from
# Documentation/WindowsBringup.md: build Husk's allocator into the iOS QEMU
# library, preserve non-iOS and interpreter builds, and export the
# coordination symbols the app needs. The vendored sources live under
# patches/data/qemu-10.0.12-utm/tcg/ and are copied into the tree here, so a
# -rebuild run (which skips the download step) still gets them.
#
# Idempotent: every edit checks for its own result before touching anything,
# and the whole script aborts the dependency build on any mismatch it does not
# recognise. That matters on CI -- a silent partial integration would show up
# only as a VM that cannot obtain executable memory.
#
# Line endings are handled explicitly rather than relied upon: the pinned
# qemu-10.0.12-utm sources use CRLF, and a patch(1) built with LF context does
# not apply to them.

import shutil
import sys
from pathlib import Path

failures = []


def read_lines(path):
    """Return list of (body_without_eol, full_raw_line) or [] on error."""
    if not path.exists():
        failures.append(f"{path}: file does not exist")
        return []
    raw = path.read_bytes().decode("utf-8", "strict")
    return [(ln.rstrip("\r\n"), ln) for ln in raw.splitlines(keepends=True)]


def eol_of(path, lines):
    """Majority line terminator of a file ('\\r\\n' / '\\n' / '')."""
    counts = {"\r\n": 0, "\n": 0, "": 0}
    for _, raw in lines:
        counts["\r\n" if raw.endswith("\r\n") else ("\n" if raw.endswith("\n") else "")] += 1
    best = max(counts, key=counts.get)
    # empty only wins if the file genuinely has no terminator anywhere
    return "" if counts[""] >= counts[best] or counts[best] == 0 else best


def find_index(lines, predicate):
    for i, (body, _) in enumerate(lines):
        if predicate(body):
            return i
    return -1


def insert_after(path, index, lines, block_lines):
    """Insert block_lines (plain str bodies, no EOL) after line index."""
    eol = eol_of(path, lines)
    out = lines[:index + 1]
    out += [(line, line + eol) for line in block_lines]
    out += lines[index + 1:]
    path.write_bytes("".join(raw for _, raw in out).encode("utf-8"))


def find_repo_dir(tree):
    """Walk up from the QEMU tree until the vendored husk sources appear.

    The script is invoked both from the repo root and from CI (where the tree
    lives somewhere entirely different), so 'three levels up' is not an
    assumption the script can afford.
    """
    candidates = [tree, *tree.parents,
                  Path.cwd(), *Path.cwd().parents]
    for cand in candidates:
        if (cand / "patches" / "data" / "qemu-10.0.12-utm" / "tcg").is_dir():
            return cand
    return None


def check(condition, message):
    if condition:
        print(f"[ok  ] {message}")
    else:
        failures.append(message)
        print(f"[FAIL] {message}")


def main():
    tree = Path(sys.argv[1]).resolve()
    repo = (Path(sys.argv[2]).resolve() if len(sys.argv) > 2
            else find_repo_dir(tree))
    if repo is None:
        failures.append("husk vendored sources not found: pass the repo root "
                        "(containing patches/data/qemu-10.0.12-utm/tcg) as "
                        "argument 2")
        return finish()

    data = repo / "patches" / "data" / "qemu-10.0.12-utm" / "tcg"
    tcg_dir = tree / "tcg"

    # ------------------------------------------------- 1. vendored sources
    for name in ("husk-ios-jit.h", "husk-ios-jit.c", "husk-brk.c"):
        src = data / name
        dst = tcg_dir / name
        if not src.exists():
            failures.append(f"{src}: vendored source missing from the repo")
            continue
        if not dst.exists():
            print(f"[copy] {name} -> tcg/")
            shutil.copyfile(src, dst)
        elif src.read_bytes() != dst.read_bytes():
            print(f"[sync] {name} -> tcg/ (older copy overwritten)")
            shutil.copyfile(src, dst)

    if failures:
        return finish()

    # ------------------------------------------------------- 2. region.c
    region = tcg_dir / "region.c"
    rl = read_lines(region)
    if rl:
        text = "".join(raw for _, raw in rl)

        i_include = find_index(rl, lambda l: l == '#include "host/cpuinfo.h"')
        if "husk-ios-jit.h" not in text:
            if i_include < 0:
                failures.append(f"{region}: could not find include block")
                return finish()
            block = [
                "",
                "#ifdef __APPLE__",
                "#include <TargetConditionals.h>",
                "#endif",
                "#if defined(__APPLE__) && TARGET_OS_IPHONE",
                '#include "husk-ios-jit.h"',
                "#endif",
            ]
            insert_after(region, i_include, rl, block)
            rl = read_lines(region)
            print("[ok  ] region.c: husk include block added")

        text = "".join(raw for _, raw in rl)
        if "alloc_code_gen_buffer_splitwx_husk_ios" not in text:
            i_splitwx = find_index(
                rl, lambda l: l.startswith("static int alloc_code_gen_buffer_splitwx("))
            if i_splitwx < 0:
                failures.append(f"{region}: could not find alloc_code_gen_buffer_splitwx")
                return finish()
            block = [
                "/*",
                " * WinPocket: a second way to get executable memory on iOS.",
                " *",
                " * The vmremap path below, which UTM ships in this tree, covers a",
                " * plain MAP_JIT/CS_DEBUGGED process on a device without TXM. Since",
                " * iOS 26 every device enforces TXM: an app cannot map or mprotect",
                " * anything executable, and the pages can only be granted by an",
                " * attached debugger servicing brk traps (StikDebug, via",
                " * BreakpointJIT). The request must happen while that debugger is",
                " * still attached, which is also why the app can prewarm the whole",
                " * region with husk_ios_jit_prewarm() well before qemu_init() and",
                " * have QEMU receive the same pages here.",
                " *",
                " * husk_ios_jit_install_trap_handler() turns an unserviced brk into",
                " * a NULL reply instead of process death, so this stays safe when",
                " * the debugger is simply not there -- in that case the caller",
                " * below falls through to the vmremap path and behaves exactly as",
                " * it did before this block existed.",
                " *",
                " * Both guards matter: interpreter builds have no code buffer at" ,
                " * all, and non-Apple builds have no debugger protocol, so the",
                " * function disappears on both rather than sitting unused.",
                " */",
                "#if !defined(CONFIG_TCG_INTERPRETER) && !defined(CONFIG_TCG_THREADED_INTERPRETER) && \\",
                "    defined(__APPLE__) && TARGET_OS_IPHONE",
                "static int alloc_code_gen_buffer_splitwx_husk_ios(size_t size, Error **errp)",
                "{",
                "    HuskDualMapping m;",
                "    size_t page = 16384; /* the debugger prepares whole 16 KiB pages */",
                "",
                "    size = ROUND_UP(size, page);",
                "    husk_ios_jit_install_trap_handler();",
                "    m = husk_ios_jit_allocate(size);",
                "    if (m.rw_addr == NULL) {",
                "        error_setg(errp,",
                "                   \"husk: could not obtain %zu bytes of JIT memory. Attach \"",
                "                   \"StikDebug with the Universal JIT script before booting, \"",
                "                   \"or let the app request JIT at launch.\",",
                "                   size);",
                "        return -1;",
                "    }",
                "",
                "    region.start_aligned = m.rw_addr;",
                "    region.total_size = m.size;",
                "    tcg_splitwx_diff = m.rx_addr - m.rw_addr;",
                "    return PROT_READ | PROT_WRITE;",
                "}",
                "#endif /* no TCG interpreter, and target is an iPhone/iPad */",
                "",
            ]
            insert_after(region, i_splitwx - 1, rl, block)
            rl = read_lines(region)
            print("[ok  ] region.c: husk allocator hook added")

        # Try the husk path first inside alloc_code_gen_buffer_splitwx, falling
        # back to the vmremap path UTM ships when it fails. The anchor is two
        # lines wide -- the interpreter guard directly followed by the macOS
        # branch -- because the same guard text appears alone near the top of
        # the file (around the vmremap includes), and that one must not match.
        i_dispatch = -1
        for idx in range(len(rl) - 1):
            b, _ = rl[idx]
            nb, _ = rl[idx + 1]
            if (b.strip().startswith("#if !defined(CONFIG_TCG_INTERPRETER)")
                    and b.strip().endswith("!defined(CONFIG_TCG_THREADED_INTERPRETER)")
                    and nb.strip() == "# ifdef CONFIG_DARWIN"):
                i_dispatch = idx
                break
        if i_dispatch >= 0:
            if "alloc_code_gen_buffer_splitwx_husk_ios(size," not in "".join(raw for _, raw in rl):
                block = [
                    "# if defined(__APPLE__) && TARGET_OS_IPHONE",
                    "    /*",
                    "     * WinPocket: try the debugger-serviced dual mapping first. On",
                    "     * failure, free the error and fall through to the paths QEMU",
                    "     * already had, preserving the pre-TXM behaviour unchanged.",
                    "     */",
                    "    if (alloc_code_gen_buffer_splitwx_husk_ios(size, errp) >= 0) {",
                    "        return PROT_READ | PROT_WRITE;",
                    "    }",
                    "    error_free_or_abort(errp);",
                    "# endif",
                ]
                insert_after(region, i_dispatch, rl, block)
                rl = read_lines(region)
                print("[ok  ] region.c: splitwx now prefers the husk dual mapping")

        # Three hard checks that the integration landed as intended.
        text = "".join(raw for _, raw in read_lines(region))
        check("husk_ios_jit_allocate(size)" in text, "region.c calls husk_ios_jit_allocate")
        check(text.count("alloc_code_gen_buffer_splitwx_husk_ios") == 2,
              "region.c defines and calls the husk hook exactly once each")
        check('#include "husk-ios-jit.h"' in text, "region.c includes husk-ios-jit.h")

    if failures:
        return finish()

    # --------------------------------------------------- 3. tcg/meson.build
    meson = tcg_dir / "meson.build"
    ml = read_lines(meson)
    if ml:
        text = "".join(raw for _, raw in ml)
        if "husk-ios-jit.c" not in text:
            i_files = find_index(ml, lambda l: l.strip() == "tcg_ss.add(files(")
            if i_files < 0:
                failures.append(f"{meson}: could not find tcg_ss.add(files(")
                return finish()
            indent = "  "
            block = [
                indent + "'husk-ios-jit.c',",
                indent + "'husk-brk.c',",
            ]
            insert_after(meson, i_files, ml, block)
            print("[ok  ] meson.build: husk sources added to tcg_ss")
        text = "".join(raw for _, raw in read_lines(meson))
        check("'husk-ios-jit.c'" in text and "'husk-brk.c'" in text,
              "meson.build compiles the husk sources")

    # -------------------------------------------------- 4. qemu.symbols
    symfile = tree / "system" / "qemu.symbols"
    sl = read_lines(symfile)
    if sl:
        wanted = [
            "husk_ios_available_memory",
            "husk_ios_jit_allocate",
            "husk_ios_jit_detach",
            "husk_ios_jit_get_mapping",
            "husk_ios_jit_install_trap_handler",
            "husk_ios_jit_is_available",
            "husk_ios_jit_log_footprint",
            "husk_ios_jit_mapjit_works",
            "husk_ios_jit_prewarm",
            "husk_ios_jit_prewarm_self",
            "husk_ios_jit_release",
            "husk_ios_jit_reserve_bottom",
            "husk_ios_jit_self_route",
        ]
        present = {b.strip().rstrip(";") for b, _ in sl}
        missing_names = [w for w in wanted if w not in present]
        if missing_names:
            i_open = find_index(sl, lambda l: l.strip() == "{")
            if i_open < 0:
                failures.append(f"{symfile}: could not find opening brace")
                return finish()
            block = ["  " + w + ";" for w in missing_names]
            insert_after(symfile, i_open, sl, block)
            print(f"[ok  ] qemu.symbols: exported {len(missing_names)} husk symbols")
        text = "".join(raw for _, raw in read_lines(symfile))
        check(all((w + ";") in text for w in wanted),
              "qemu.symbols exports the app-facing husk symbols")

    finish()


def finish():
    if failures:
        print("husk-jit-integrate: FAILED", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)
    print("[done] husk-jit integration complete and verified")


if __name__ == "__main__":
    main()
