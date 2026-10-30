#!/usr/bin/env python3
# WinPocket: integrate the Husk backend into an unpacked QEMU tree.
#
# The Husk JIT substrate is wired in by husk-jit-integrate.py. This script is the
# other half: the modules that let the iOS app drive the machine directly instead
# of through SPICE.
#
#   ui/husk-display.c       DisplayChangeListener -> CPU framebuffer the app reads
#   ui/husk-display-gl.c    virgl scanout -> CAMetalLayer, via ANGLE
#   audio/husk-audio.c      iOS audio backend ("-audiodev husk"), ring-buffered
#   system/husk-balloon.c   host-driven balloon under jetsam pressure
#   system/husk-snapshot.c  savevm/loadvm of the whole machine
#
# QEMU's UI and audio pieces are not plugins: the sources have to be in the build,
# the driver has to be in the QAPI enum, and every app-facing function has to be
# on the shared library's export list. Each of those is a place to fail quietly,
# so this script edits all of them and then verifies its own result.
#
# Idempotent, and the whole dependency build aborts on any shape it does not
# recognise -- a partial integration would show up only as a black screen or a
# missing audio driver at runtime, neither of which points back here.
#
# Line endings are preserved: the pinned qemu-10.0.12-utm sources are mixed and
# the edits are made in whichever terminator the file already uses.

import shutil
import sys
from pathlib import Path

failures = []

# Vendored sources, relative to patches/data/qemu-10.0.12-utm.
VENDORED = [
    "ui/husk-display.c",
    "ui/husk-display.h",
    "ui/husk-display-gl.c",
    "ui/husk-display-gl.h",
    "audio/husk-audio.c",
    "audio/husk-audio.h",
    "system/husk-balloon.c",
    "system/husk-balloon.h",
    "system/husk-snapshot.c",
    "system/husk-snapshot.h",
]

# Everything the app links against. The shared-lib build exports only what is on
# this list, so a function missing here is a link error in Xcode, not at runtime.
EXPORTED = [
    "husk_display_init",
    "husk_display_lock_frame",
    "husk_display_unlock_frame",
    "husk_display_sequence",
    "husk_display_set_ui_size",
    "husk_display_guest_size",
    "husk_display_send_pointer",
    "husk_display_send_key",
    "husk_display_request_update",
    "husk_display_gl_early",
    "husk_display_gl_create",
    "husk_display_gl_probe",
    "husk_display_gl_bind",
    "husk_display_gl_frames",
    "husk_display_gl_set_metal_presenter",
    "husk_audio_pull",
    "husk_audio_active",
    "husk_audio_frames_in",
    "husk_audio_underruns",
    "husk_balloon_set_bytes",
    "husk_snapshot_save",
    "husk_snapshot_load_at_startup",
]


def read_lines(path):
    """Return list of (body_without_eol, full_raw_line) or [] on error."""
    if not path.exists():
        failures.append(f"{path}: file does not exist")
        return []
    raw = path.read_bytes().decode("utf-8", "strict")
    return [(ln.rstrip("\r\n"), ln) for ln in raw.splitlines(keepends=True)]


def eol_of(lines):
    """Majority line terminator of a file."""
    counts = {"\r\n": 0, "\n": 0, "": 0}
    for _, raw in lines:
        counts["\r\n" if raw.endswith("\r\n") else ("\n" if raw.endswith("\n") else "")] += 1
    best = max(counts, key=counts.get)
    return "" if counts[best] == 0 else best


def find_index(lines, predicate):
    for i, (body, _) in enumerate(lines):
        if predicate(body):
            return i
    return -1


def insert_after(path, index, lines, block_lines):
    """Insert block_lines (plain str bodies, no EOL) after line index."""
    eol = eol_of(lines)
    out = lines[:index + 1]
    out += [(line, line + eol) for line in block_lines]
    out += lines[index + 1:]
    path.write_bytes("".join(raw for _, raw in out).encode("utf-8"))


def write_text_preserving_eol(path, lines, text):
    eol = eol_of(lines)
    path.write_bytes(text.replace("\r\n", "\n").replace("\n", eol).encode("utf-8"))


def check(condition, message):
    if condition:
        print(f"[ok  ] {message}")
    else:
        failures.append(message)
        print(f"[FAIL] {message}")


def find_repo_dir(tree):
    """Walk up until the vendored husk sources appear, as the JIT script does."""
    for cand in [tree, *tree.parents, Path.cwd(), *Path.cwd().parents]:
        if (cand / "patches" / "data" / "qemu-10.0.12-utm" / "ui" / "husk-display.c").is_file():
            return cand
    return None


def main():
    tree = Path(sys.argv[1]).resolve()
    repo = (Path(sys.argv[2]).resolve() if len(sys.argv) > 2
            else find_repo_dir(tree))
    if repo is None:
        failures.append("vendored husk sources not found: pass the repo root "
                        "(containing patches/data/qemu-10.0.12-utm/ui) as "
                        "argument 2")
        return finish()

    data = repo / "patches" / "data" / "qemu-10.0.12-utm"

    # ------------------------------------------------- 1. vendored sources
    for rel in VENDORED:
        src = data / rel
        dst = tree / rel
        if not src.exists():
            failures.append(f"{src}: vendored source missing from the repo")
            continue
        if not dst.parent.is_dir():
            failures.append(f"{dst.parent}: destination directory missing")
            continue
        if not dst.exists():
            print(f"[copy] {rel}")
            shutil.copyfile(src, dst)
        elif src.read_bytes() != dst.read_bytes():
            print(f"[sync] {rel} (older copy overwritten)")
            shutil.copyfile(src, dst)

    if failures:
        return finish()

    # ------------------------------------------------------ 2. ui/meson.build
    ui_meson = tree / "ui" / "meson.build"
    ml = read_lines(ui_meson)
    if ml:
        text = "".join(raw for _, raw in ml)
        if "'husk-display.c'" not in text:
            i_files = find_index(ml, lambda l: l.strip() == "system_ss.add(files(")
            if i_files < 0:
                failures.append(f"{ui_meson}: could not find system_ss.add(files(")
                return finish()
            insert_after(ui_meson, i_files, ml, ["  'husk-display.c',"])
            ml = read_lines(ui_meson)
            print("[ok  ] ui/meson.build: husk-display.c added to system_ss")

        text = "".join(raw for _, raw in read_lines(ui_meson))
        # The GL path shares the block with QEMU's own shader.c/console-gl.c, so
        # it is compiled exactly when CONFIG_OPENGL is on and linked into the
        # emulator (modules are disabled in this build) rather than a plugin.
        if "'husk-display-gl.c'" not in text:
            old = "files('shader.c', 'console-gl.c')"
            new = "files('shader.c', 'console-gl.c', 'husk-display-gl.c')"
            ml = read_lines(ui_meson)
            if old not in "".join(raw for _, raw in ml):
                failures.append(f"{ui_meson}: could not find the shader.c/console-gl.c block")
                return finish()
            write_text_preserving_eol(ui_meson, ml,
                                      "".join(raw for _, raw in ml).replace(old, new, 1))
            print("[ok  ] ui/meson.build: husk-display-gl.c added to the OpenGL block")

        text = "".join(raw for _, raw in read_lines(ui_meson))
        check("'husk-display.c'" in text, "ui/meson.build compiles husk-display.c")
        check("'husk-display-gl.c'" in text, "ui/meson.build compiles husk-display-gl.c")
        check(text.count("'husk-display.c'") == 1, "husk-display.c listed exactly once")
        check(text.count("'husk-display-gl.c'") == 1, "husk-display-gl.c listed exactly once")

    if failures:
        return finish()

    # --------------------------------------------------- 3. audio/meson.build
    audio_meson = tree / "audio" / "meson.build"
    ml = read_lines(audio_meson)
    if ml:
        text = "".join(raw for _, raw in ml)
        if "'husk-audio.c'" not in text:
            i_noaudio = find_index(ml, lambda l: l.strip() == "'noaudio.c',")
            if i_noaudio < 0:
                failures.append(f"{audio_meson}: could not find 'noaudio.c'")
                return finish()
            insert_after(audio_meson, i_noaudio - 1, ml, ["  'husk-audio.c',"])
            print("[ok  ] audio/meson.build: husk-audio.c added")
        text = "".join(raw for _, raw in read_lines(audio_meson))
        check("'husk-audio.c'" in text and text.count("'husk-audio.c'") == 1,
              "audio/meson.build compiles husk-audio.c exactly once")

    # ------------------------------- 4. audio/audio_template.h (pdo switches)
    # audio_get_pdo_in() and audio_get_pdo_out() switch over every driver by hand
    # and neither has a default: an enum member without a case falls off the end
    # into a bare abort() with no message. The file is included twice (TYPE=in
    # and TYPE=out), so one textual case covers both directions.
    template = tree / "audio" / "audio_template.h"
    tl = read_lines(template)
    if tl:
        text = "".join(raw for _, raw in tl)
        if "AUDIODEV_DRIVER_HUSK" not in text:
            i_wav = find_index(tl, lambda l: l.strip() == "case AUDIODEV_DRIVER_WAV:")
            if i_wav < 0:
                failures.append(f"{template}: could not find the WAV pdo case")
                return finish()
            insert_after(template, i_wav - 1, tl, [
                "    case AUDIODEV_DRIVER_HUSK:",
                "        return dev->u.husk.TYPE;",
                "",
            ])
            print("[ok  ] audio/audio_template.h: audio_get_pdo_* knows the husk driver")
        text = "".join(raw for _, raw in read_lines(template))
        check(text.count("AUDIODEV_DRIVER_HUSK") == 1,
              "audio_template.h handles the husk driver once")

    # ------------------------------------------------------ 5. audio/audio.c
    # The other switch allocates the per-direction options. Without a case the
    # pointers stay NULL; with only one of the two switches fixed, the crash
    # moves instead of going away.
    audio_c = tree / "audio" / "audio.c"
    al = read_lines(audio_c)
    if al:
        text = "".join(raw for _, raw in al)
        if "CASE(HUSK" not in text:
            i_none = find_index(al, lambda l: l.strip() == "CASE(NONE, none, );")
            if i_none < 0:
                failures.append(f"{audio_c}: could not find CASE(NONE, none, );")
                return finish()
            insert_after(audio_c, i_none, al, ["        CASE(HUSK, husk, );"])
            print("[ok  ] audio/audio.c: husk gets per-direction options allocated")
        text = "".join(raw for _, raw in read_lines(audio_c))
        check(text.count("CASE(HUSK") == 1, "audio.c registers the husk options once")

    # ------------------------------------------------------- 6. qapi/audio.json
    # -audiodev is parsed through a QAPI union whose discriminator is a closed
    # enum, so an unknown name is rejected before any driver is consulted.
    # Registering the driver alone is not enough.
    audio_json = tree / "qapi" / "audio.json"
    jl = read_lines(audio_json)
    if jl:
        text = "".join(raw for _, raw in jl)
        if "'husk'" not in text:
            enum_old = "{ 'enum': 'AudiodevDriver',\n  'data': [ 'none',"
            enum_new = "{ 'enum': 'AudiodevDriver',\n  'data': [ 'none',\n            'husk',"
            union_old = "  'data': {\n    'none':      'AudiodevGenericOptions',"
            union_new = ("  'data': {\n    'none':      'AudiodevGenericOptions',\n"
                         "    'husk':      'AudiodevGenericOptions',")
            if enum_old not in text:
                failures.append(f"{audio_json}: AudiodevDriver enum shape changed")
                return finish()
            if union_old not in text:
                failures.append(f"{audio_json}: Audiodev union shape changed")
                return finish()
            text = text.replace(enum_old, enum_new, 1).replace(union_old, union_new, 1)
            write_text_preserving_eol(audio_json, jl, text)
            print("[ok  ] qapi/audio.json: -audiodev husk is a valid driver")
        text = "".join(raw for _, raw in read_lines(audio_json))
        check(text.count("'husk',") == 1 and text.count("'husk':") == 1,
              "qapi/audio.json declares husk in the enum and the union exactly once")

    # -------------------------------------------------- 7. system/meson.build
    system_meson = tree / "system" / "meson.build"
    sl = read_lines(system_meson)
    if sl:
        text = "".join(raw for _, raw in sl)
        added = False
        if "'husk-balloon.c'" not in text:
            i_files = find_index(sl, lambda l: l.strip() == "system_ss.add(files(")
            if i_files < 0:
                failures.append(f"{system_meson}: could not find system_ss.add(files(")
                return finish()
            insert_after(system_meson, i_files, sl, ["  'husk-balloon.c',"])
            sl = read_lines(system_meson)
            added = True
        text = "".join(raw for _, raw in read_lines(system_meson))
        if "'husk-snapshot.c'" not in text:
            i_files = find_index(sl, lambda l: l.strip() == "system_ss.add(files(")
            if i_files < 0:
                failures.append(f"{system_meson}: could not find system_ss.add(files(")
                return finish()
            insert_after(system_meson, i_files, sl, ["  'husk-snapshot.c',"])
            added = True
        text = "".join(raw for _, raw in read_lines(system_meson))
        check("'husk-balloon.c'" in text and "'husk-snapshot.c'" in text,
              "system/meson.build compiles the balloon and snapshot modules")
        if added:
            print("[ok  ] system/meson.build: husk system modules added")

    # ---------------------------------------------------- 8. qemu.symbols
    # On darwin meson seds this into an ld64 -exported_symbols_list, so a symbol
    # absent here simply is not visible to the app even though it is in the dylib.
    symfile = tree / "system" / "qemu.symbols"
    syml = read_lines(symfile)
    if syml:
        present = {b.strip().rstrip(";") for b, _ in syml}
        missing = [name for name in EXPORTED if name not in present]
        if missing:
            i_open = find_index(syml, lambda l: l.strip() == "{")
            if i_open < 0:
                failures.append(f"{symfile}: could not find opening brace")
                return finish()
            insert_after(symfile, i_open, syml, ["  " + name + ";" for name in missing])
            print(f"[ok  ] qemu.symbols: exported {len(missing)} husk symbols")
        text = "".join(raw for _, raw in read_lines(symfile))
        check(all((name + ";") in text for name in EXPORTED),
              "qemu.symbols exports the app-facing husk backend symbols")

    finish()


def finish():
    if failures:
        print("husk-backend-integrate: FAILED", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)
    print("[done] husk backend integration complete and verified")


if __name__ == "__main__":
    main()
