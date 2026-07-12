#!/usr/bin/env python3
"""Symbolicate a MetricKit crash report from the `crash_reports` table.

Usage:
    python3 tools/symbolicate_metrickit.py <report.json> <binary>

<report.json>  Either a full crash_reports row (with a "call_stack" key) or
               the bare MetricKit callStackTree JSON. Copy it from the
               Supabase dashboard (call_stack cell -> save to a file).
<binary>       Something containing symbols for the EXACT build that crashed:
               - a .dSYM bundle (from an Xcode archive), or
               - the DuelFantasy.app bundle / bare Mach-O from a debug build
                 (~/Library/Developer/Xcode/DerivedData/.../DuelFantasy.app).

Non-app frames (libswiftCore, UIKitCore, ...) are printed with their binary
name and address only — the app's own frames are what pinpoint the crash.
"""

import json
import os
import subprocess
import sys


def find_macho(path):
    """Resolve a .dSYM/.app bundle (or bare binary) to its Mach-O file."""
    if os.path.isfile(path):
        return path
    if path.endswith(".dSYM"):
        dwarf_dir = os.path.join(path, "Contents", "Resources", "DWARF")
        entries = os.listdir(dwarf_dir)
        return os.path.join(dwarf_dir, entries[0])
    if path.endswith(".app"):
        name = os.path.splitext(os.path.basename(path))[0]
        return os.path.join(path, name)
    sys.exit(f"error: can't find a Mach-O binary inside {path}")


def walk(frame, depth, frames):
    frames.append((depth, frame))
    for sub in frame.get("subFrames", []):
        walk(sub, depth + 1, frames)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    report_path, binary_path = sys.argv[1], sys.argv[2]
    macho = find_macho(binary_path)
    app_binary = os.path.basename(macho)

    with open(report_path) as f:
        data = json.load(f)
    tree = data.get("call_stack", data)
    if isinstance(tree, str):
        tree = json.loads(tree)

    for meta in ("kind", "app_version", "os_version", "signal", "exception_type",
                 "termination_reason", "crashed_at"):
        if meta in data:
            print(f"{meta}: {data[meta]}")

    call_stacks = tree.get("callStacks", [])
    for i, stack in enumerate(call_stacks):
        attributed = stack.get("threadAttributed", False)
        # For crashes the attributed thread is the one that crashed.
        print(f"\n=== Thread {i}{' (CRASHED)' if attributed else ''} ===")
        frames = []
        for root in stack.get("callStackRootFrames", []):
            walk(root, 0, frames)

        # Batch-symbolicate the app's own frames with one atos call.
        app_frames = [(n, fr) for n, (_, fr) in enumerate(frames)
                      if fr.get("binaryName") == app_binary]
        symbolicated = {}
        if app_frames:
            # __TEXT load address = frame address - offset into text segment;
            # identical for every frame of the same loaded binary.
            _, first = app_frames[0]
            load_addr = first["address"] - first["offsetIntoBinaryTextSegment"]
            addrs = [hex(fr["address"]) for _, fr in app_frames]
            out = subprocess.run(
                ["atos", "-o", macho, "-arch", "arm64", "-l", hex(load_addr)] + addrs,
                capture_output=True, text=True,
            ).stdout.strip().splitlines()
            for (n, _), line in zip(app_frames, out):
                symbolicated[n] = line

        for n, (_, fr) in enumerate(frames):
            name = fr.get("binaryName", "?")
            addr = fr.get("address", 0)
            sym = symbolicated.get(n)
            marker = ">>" if sym else "  "
            print(f"{marker} {n:3d} {name:<28} {sym or hex(addr)}")


if __name__ == "__main__":
    main()
