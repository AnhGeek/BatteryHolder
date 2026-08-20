#!/usr/bin/env python3
"""Build the reference firmware and stage it as Android app assets.

The phone never compiles anything: it ships finished `.bin` images and pushes
them to a board over USB with the ROM serial bootloader. This script is what
produces those images, one set per entry in `android_app/assets/boards.json`,
plus the `manifest.json` that tells the app where each part goes in flash.

    python tools/build_firmware.py                 # all boards
    python tools/build_firmware.py --board esp32-wroom
    python tools/build_firmware.py --check         # report, build nothing

Requires `arduino-cli` with the esp32 and/or esp8266 cores and ArduinoJson
installed. Point at a non-default install with --arduino-cli / --data-dir /
--user-dir, or the ARDUINO_CLI / ARDUINO_DIRECTORIES_DATA /
ARDUINO_DIRECTORIES_USER environment variables.

Boards whose core is missing are skipped with a warning: the manifest then
describes only what was actually built, and the app offers USB flashing for
exactly those boards.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BOARDS_JSON = REPO / "android_app" / "assets" / "boards.json"
ASSET_ROOT = REPO / "android_app" / "assets" / "firmware"
FIRMWARE = REPO / "firmware"

# How each catalog board is built. `sketch` is a folder under firmware/.
BUILD_TARGETS = {
    "esp32-wroom": {
        "sketch": "battery_holder_node",
        "fqbn": "esp32:esp32:esp32:PartitionScheme=min_spiffs",
    },
    "esp32c3-devkit": {
        # CDCOnBoot puts the sketch's console on the chip's native USB port, so
        # the phone can talk to the board over the same cable it flashed it
        # with. Without it Serial stays on UART0 and a board plugged into its
        # USB socket answers nothing.
        "sketch": "battery_holder_node",
        "fqbn": "esp32:esp32:esp32c3:PartitionScheme=min_spiffs,CDCOnBoot=cdc",
    },
    "esp8266-nodemcu": {
        "sketch": "esp8266_node",
        "fqbn": "esp8266:esp8266:nodemcuv2",
    },
    "esp8266-d1mini": {
        "sketch": "esp8266_node",
        "fqbn": "esp8266:esp8266:d1_mini",
    },
}

PARTITION_MAGIC = 0x50AA  # bytes AA 50, little-endian
SECTOR = 0x1000


def sh(cmd: list[str], env: dict[str, str], cwd: Path | None = None) -> str:
    out = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if out.returncode != 0:
        sys.stderr.write(out.stdout[-4000:] + "\n" + out.stderr[-4000:] + "\n")
        raise SystemExit(f"command failed: {' '.join(cmd[:3])} …")
    return out.stdout


def md5_of(path: Path) -> str:
    return hashlib.md5(path.read_bytes()).hexdigest()


def parse_partitions(blob: bytes) -> list[dict]:
    """Decode a built partitions.bin into its entries."""
    entries = []
    for off in range(0, len(blob), 32):
        chunk = blob[off:off + 32]
        if len(chunk) < 32:
            break
        magic, ptype, subtype, addr, size, label, flags = struct.unpack(
            "<HBBII16sI", chunk)
        if magic != PARTITION_MAGIC:
            break
        entries.append({
            "type": ptype,
            "subtype": subtype,
            "offset": addr,
            "size": size,
            "label": label.rstrip(b"\x00").decode("ascii", "replace"),
        })
    return entries


def parse_flash_args(text: str) -> tuple[dict, list[tuple[int, str]]]:
    """Read the core's flash_args file: options line, then offset/file pairs."""
    options, parts = {}, []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("--"):
            tokens = line.split()
            for i in range(0, len(tokens) - 1, 2):
                if tokens[i].startswith("--"):
                    options[tokens[i][2:]] = tokens[i + 1]
            continue
        offset, _, name = line.partition(" ")
        parts.append((int(offset, 16), name.strip()))
    return options, parts


def elf_symbol(nm: Path, elf: Path, symbol: str, env: dict[str, str]) -> int | None:
    """Look one absolute linker symbol up in a built ELF."""
    for line in sh([str(nm), str(elf)], env).splitlines():
        bits = line.split()
        if len(bits) == 3 and bits[2] == symbol:
            return int(bits[0], 16)
    return None


def find_tool(data_dir: Path, package: str, tool: str, exe: str) -> Path | None:
    root = data_dir / "packages" / package / "tools" / tool
    if not root.is_dir():
        return None
    for version in sorted(root.iterdir(), reverse=True):
        candidate = version / "bin" / exe
        if candidate.exists():
            return candidate
        candidate = candidate.with_suffix(".exe")
        if candidate.exists():
            return candidate
    return None


def installed_cores(cli: str, env: dict[str, str]) -> set[str]:
    try:
        raw = sh([cli, "core", "list", "--format", "json"], env)
    except SystemExit:
        return set()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return set()
    rows = data.get("platforms", data) if isinstance(data, dict) else data
    ids = set()
    for row in rows:
        pid = row.get("id") or (row.get("platform") or {}).get("id")
        if pid:
            ids.add(pid)
    return ids


def firmware_version() -> str:
    text = (FIRMWARE / "battery_holder_node" / "battery_holder_node.ino").read_text(
        encoding="utf-8")
    match = re.search(r'FW_VERSION\s*=\s*"([^"]+)"', text)
    return match.group(1) if match else "0.0.0"


def build_board(board_id: str, spec: dict, cli: str, env: dict[str, str],
                build_root: Path, data_dir: Path) -> dict:
    sketch = FIRMWARE / spec["sketch"]
    build_path = build_root / board_id
    build_path.mkdir(parents=True, exist_ok=True)

    print(f"  compiling {board_id} ({spec['fqbn']})")
    sh([cli, "compile", "--fqbn", spec["fqbn"], "--build-path", str(build_path),
        str(sketch)], env)

    out_dir = ASSET_ROOT / board_id
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    bundle = {
        "boardId": board_id,
        "sketch": spec["sketch"],
        "fqbn": spec["fqbn"],
        "parts": [],
    }

    flash_args = build_path / "flash_args"
    if flash_args.exists():
        # ESP32: bootloader + partition table + boot_app0 + app, offsets and
        # flash options straight from what the core would have flashed itself.
        options, parts = parse_flash_args(flash_args.read_text(encoding="utf-8"))
        bundle["flashMode"] = options.get("flash-mode", "dio")
        bundle["flashFreq"] = options.get("flash-freq", "40m")
        bundle["flashSize"] = options.get("flash-size", "4MB")

        for offset, name in parts:
            src = build_path / name
            if not src.exists():
                raise SystemExit(f"missing build artifact {src}")
            # Strip the sketch prefix: bootloader.bin reads better than
            # battery_holder_node.ino.bootloader.bin in a manifest. The app
            # image itself is left with nothing but its extension, so name it.
            short = name.replace(f"{spec['sketch']}.ino.", "")
            if short == "bin":
                short = "firmware.bin"
            shutil.copy2(src, out_dir / short)
            bundle["parts"].append({
                "file": short,
                "offset": offset,
                "size": src.stat().st_size,
                "md5": md5_of(src),
            })

        table = parse_partitions(
            (build_path / f"{spec['sketch']}.ino.partitions.bin").read_bytes())
        calib = next((p for p in table if p["label"] == "calib"), None)
        if calib is None:
            raise SystemExit(
                f"{board_id}: no `calib` partition — check firmware/{spec['sketch']}/partitions.csv")
        bundle["calibration"] = {"offset": calib["offset"], "size": calib["size"]}

        # Blanking NVS is what makes a reflashed board behave like a new one:
        # it holds the saved pin config, the run mode and the sleep intervals,
        # so a board left on a short test cycle would otherwise stay on it.
        # otadata is deliberately left out — boot_app0.bin is written over it a
        # moment later, which is what points the bootloader back at app0.
        nvs = next((p for p in table if p["label"] == "nvs"), None)
        if nvs:
            bundle["eraseRegions"] = [
                {"offset": nvs["offset"], "size": nvs["size"], "label": "nvs"}]
    else:
        # ESP8266: one image at 0, and a calibration sector derived from the
        # same linker symbol the sketch reads at runtime.
        image = build_path / f"{spec['sketch']}.ino.bin"
        shutil.copy2(image, out_dir / "firmware.bin")
        bundle["flashMode"] = "dio"
        bundle["flashFreq"] = "40m"
        bundle["flashSize"] = "4MB"
        bundle["parts"].append({
            "file": "firmware.bin",
            "offset": 0,
            "size": image.stat().st_size,
            "md5": md5_of(image),
        })

        nm = find_tool(data_dir, "esp8266", "xtensa-lx106-elf-gcc",
                       "xtensa-lx106-elf-nm")
        if nm is None:
            raise SystemExit("esp8266 nm not found; cannot locate _EEPROM_start")
        eeprom = elf_symbol(nm, build_path / f"{spec['sketch']}.ino.elf",
                            "_EEPROM_start", env)
        if eeprom is None:
            raise SystemExit(f"{board_id}: _EEPROM_start missing from the ELF")
        eeprom_offset = eeprom - 0x40200000
        bundle["calibration"] = {"offset": eeprom_offset - SECTOR, "size": SECTOR}
        # The ESP8266 keeps its whole config blob in the EEPROM sector.
        bundle["eraseRegions"] = [
            {"offset": eeprom_offset, "size": SECTOR, "label": "eeprom"}]

    return bundle


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--board", action="append", help="build only this board id")
    ap.add_argument("--arduino-cli", default=os.environ.get("ARDUINO_CLI", "arduino-cli"))
    ap.add_argument("--data-dir", default=os.environ.get("ARDUINO_DIRECTORIES_DATA"))
    ap.add_argument("--user-dir", default=os.environ.get("ARDUINO_DIRECTORIES_USER"))
    ap.add_argument("--build-dir", default=None, help="scratch dir for build output")
    ap.add_argument("--check", action="store_true",
                    help="report what would be built and exit")
    args = ap.parse_args()

    env = dict(os.environ)
    if args.data_dir:
        env["ARDUINO_DIRECTORIES_DATA"] = args.data_dir
    if args.user_dir:
        env["ARDUINO_DIRECTORIES_USER"] = args.user_dir
    data_dir = Path(env.get("ARDUINO_DIRECTORIES_DATA", Path.home() / "Arduino15"))

    catalog = json.loads(BOARDS_JSON.read_text(encoding="utf-8"))
    wanted = args.board or [b["id"] for b in catalog]
    known = {b["id"]: b for b in catalog}

    cores = installed_cores(args.arduino_cli, env)
    print(f"arduino-cli cores: {', '.join(sorted(cores)) or 'none found'}")

    if args.check:
        for board_id in wanted:
            spec = BUILD_TARGETS.get(board_id)
            core = spec["fqbn"].split(":", 2)[0] + ":" + spec["fqbn"].split(":")[1] if spec else "?"
            state = "buildable" if spec and core in cores else "skipped"
            print(f"  {board_id}: {state}")
        return 0

    build_root = Path(args.build_dir) if args.build_dir else REPO / "firmware" / ".build"
    build_root.mkdir(parents=True, exist_ok=True)
    ASSET_ROOT.mkdir(parents=True, exist_ok=True)

    bundles, skipped = {}, []
    for board_id in wanted:
        spec = BUILD_TARGETS.get(board_id)
        if spec is None:
            skipped.append((board_id, "no build target defined"))
            continue
        vendor, arch = spec["fqbn"].split(":")[:2]
        if f"{vendor}:{arch}" not in cores:
            skipped.append((board_id, f"core {vendor}:{arch} not installed"))
            continue
        bundle = build_board(board_id, spec, args.arduino_cli, env, build_root, data_dir)
        bundle["chip"] = known.get(board_id, {}).get("chip", "esp32")
        bundle["name"] = known.get(board_id, {}).get("name", board_id)
        bundles[board_id] = bundle

    manifest = {
        "schema": 1,
        "firmwareVersion": firmware_version(),
        "builtAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "bundles": bundles,
    }
    (ASSET_ROOT / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    total = sum(p["size"] for b in bundles.values() for p in b["parts"])
    print(f"\nstaged {len(bundles)} board(s), {total / 1024:.0f} KB into {ASSET_ROOT}")
    for board_id, reason in skipped:
        print(f"  skipped {board_id}: {reason}")
    if skipped:
        print("\nInstall the missing core and re-run to add those boards:")
        print("  arduino-cli core install esp8266:esp8266 --additional-urls "
              "https://arduino.esp8266.com/stable/package_esp8266com_index.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
