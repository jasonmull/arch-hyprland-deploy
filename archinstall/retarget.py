#!/usr/bin/env python3
"""Point the archinstall config at a specific disk, sized to fill it.

archinstall has no percent unit - the Unit enum is B/kB/MB/GB/... and
KiB/MiB/GiB/... plus `sectors`, and Size has no percent handling. Partition
sizes must therefore be absolute byte counts, which means the tracked config
cannot be disk-agnostic: run unchanged on a larger disk, it silently strands
whatever it does not cover.

This script reads the target disk's real size and rewrites the device path and
the root partition size to fill it, writing a new file so the tracked config
stays clean.

    ./archinstall/retarget.py /dev/nvme0n1 -o /tmp/machine.json
    archinstall --config /tmp/machine.json --creds archinstall/user_credentials.json --dry-run

Pass --disk-size-bytes to compute a layout for a disk that is not attached
(useful for checking the arithmetic before you boot the installer).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

MiB = 1024 ** 2
GiB = 1024 ** 3

# GPT keeps a backup header and partition array in the last sectors of the
# disk. 33 sectors is the minimum; 1 MiB is the conventional reservation and
# costs nothing.
GPT_TAIL_RESERVE = 1 * MiB


def disk_size_bytes(device: str) -> int:
    """Size of a block device in bytes, via lsblk."""
    try:
        out = subprocess.run(
            ["lsblk", "--bytes", "--nodeps", "--noheadings", "--output", "SIZE", device],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except FileNotFoundError:
        sys.exit("error: lsblk not found (run this from the Arch ISO or pass --disk-size-bytes)")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"error: lsblk could not read {device}: {exc.stderr.strip()}")

    if not out:
        sys.exit(f"error: {device} reported no size - is it a whole disk, not a partition?")
    return int(out.splitlines()[0])


def main() -> None:
    repo_default = Path(__file__).resolve().parent / "user_configuration.json"

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("device", help="target disk, e.g. /dev/nvme0n1, /dev/sda, /dev/vda")
    ap.add_argument("-c", "--config", type=Path, default=repo_default,
                    help="config to read (default: the tracked one)")
    ap.add_argument("-o", "--output", type=Path, default=Path("/tmp/machine.json"),
                    help="where to write the result (default: /tmp/machine.json)")
    ap.add_argument("--disk-size-bytes", type=int,
                    help="use this size instead of querying the device")
    ap.add_argument("--hostname", help="also set the hostname")
    args = ap.parse_args()

    config = json.loads(args.config.read_text())

    mods = config["disk_config"]["device_modifications"]
    if len(mods) != 1:
        sys.exit(f"error: expected exactly 1 device_modification, found {len(mods)}")
    partitions = mods[0]["partitions"]
    if len(partitions) != 2:
        sys.exit(f"error: expected exactly 2 partitions (ESP + root), found {len(partitions)}")

    esp, root = partitions
    if esp["mountpoint"] != "/boot":
        sys.exit("error: first partition is not the ESP - layout changed, update this script")
    if root["fs_type"] != "btrfs":
        sys.exit("error: second partition is not btrfs - layout changed, update this script")

    total = args.disk_size_bytes if args.disk_size_bytes else disk_size_bytes(args.device)

    # The root partition starts where the ESP ends, and runs to the end of the
    # disk minus the GPT tail reservation.
    esp_start = to_bytes(esp["start"])
    esp_size = to_bytes(esp["size"])
    root_start = esp_start + esp_size
    root_size = total - root_start - GPT_TAIL_RESERVE

    if root_size < 8 * GiB:
        sys.exit(f"error: {args.device} is only {total / GiB:.1f} GiB - "
                 f"that leaves {root_size / GiB:.1f} GiB for root, which is too small")

    mods[0]["device"] = args.device
    root["start"] = as_bytes(root_start)
    root["size"] = as_bytes(root_size)
    if args.hostname:
        config["hostname"] = args.hostname

    args.output.write_text(json.dumps(config, indent=4) + "\n")

    print(f"device      {args.device}")
    print(f"disk size   {total / GiB:>10.2f} GiB")
    print(f"ESP         {esp_size / GiB:>10.2f} GiB  at {esp_start / MiB:.0f} MiB")
    print(f"root        {root_size / GiB:>10.2f} GiB  at {root_start / GiB:.4f} GiB")
    print(f"reserved    {GPT_TAIL_RESERVE / MiB:>10.0f} MiB  (GPT backup header)")
    if args.hostname:
        print(f"hostname    {args.hostname}")
    print(f"\nwrote {args.output}")
    print("\nReview it, then dry-run before you commit to it:")
    print(f"  archinstall --config {args.output} \\")
    print("              --creds archinstall/user_credentials.json --dry-run")


def to_bytes(size: dict) -> int:
    """Convert an archinstall Size object to bytes."""
    units = {"B": 1, "KiB": 1024, "MiB": MiB, "GiB": GiB, "TiB": 1024 ** 4,
             "kB": 1000, "MB": 1000 ** 2, "GB": 1000 ** 3, "TB": 1000 ** 4}
    unit = size["unit"]
    if unit == "sectors":
        return size["value"] * size["sector_size"]["value"]
    if unit not in units:
        sys.exit(f"error: unsupported unit {unit!r} in config")
    return size["value"] * units[unit]


def as_bytes(value: int) -> dict:
    """Build an archinstall Size object denominated in bytes."""
    return {"sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": value}


if __name__ == "__main__":
    main()
