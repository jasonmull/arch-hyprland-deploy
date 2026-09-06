# arch-hyprland-deploy

Reusable, version-controlled deployment for **Arch Linux + Hyprland**: clone it onto
a fresh machine and go from bare metal to a working desktop.

Two stages:

1. **Base OS install** — an unattended `archinstall` config (`archinstall/`).
2. **Post-install** — `install.sh` installs packages and stows dotfiles. *(coming next)*

> This repository is public. No hostnames, hardware serials, usernames, or secrets
> are tracked here — see [Public repo hygiene](#public-repo-hygiene).

## Repository layout

```
archinstall/
  user_configuration.json          # unattended base install (tracked)
  user_credentials.example.json    # template for usernames/passwords (tracked)
  user_credentials.json            # your real credentials (gitignored)
LICENSE
```

## Stage 1 — base install with archinstall

Boot the Arch ISO, get networking up, then:

```bash
pacman -Sy git archinstall
git clone https://github.com/<you>/arch-hyprland-deploy /root/deploy
cd /root/deploy

# Fill in your username/passwords locally — this file is gitignored.
cp archinstall/user_credentials.example.json archinstall/user_credentials.json
vim archinstall/user_credentials.json

# Dry run first: shows the plan without touching the disk.
archinstall --config archinstall/user_configuration.json \
            --creds  archinstall/user_credentials.json \
            --dry-run

# For real:
archinstall --config archinstall/user_configuration.json \
            --creds  archinstall/user_credentials.json \
            --silent
```

Drop `--silent` if you want archinstall to show you the menu with the config
pre-loaded, so you can eyeball or tweak anything before it commits.

### What the config sets

| Setting | Value |
| --- | --- |
| Bootloader | systemd-boot |
| Filesystem | ext4 on the root partition |
| Partitioning | 1 GiB FAT32 ESP at `/boot`, rest of disk as ext4 `/` |
| Swap | enabled (zram) |
| Audio | PipeWire |
| Network | NetworkManager |
| Timezone | `America/Chicago` |
| Locale / keymap | `en_US.UTF-8`, `us` |
| Kernel | `linux` |
| Hostname | `archbox` (placeholder — change per machine) |

Packages installed at this stage are deliberately minimal (`base-devel`, `git`,
`sudo`, `vim`, `openssh`) — everything else is stage 2's job.

### Changing the target disk (do this on every new machine)

`user_configuration.json` ships with a **placeholder disk of `/dev/nvme0n1`**. It is
the single most machine-specific value in the file, and installing to the wrong
device will wipe it. Check the real device name first:

```bash
lsblk -dno NAME,SIZE,MODEL
```

Then override it **without editing the tracked file**, so `git status` stays clean:

```bash
sed 's|/dev/nvme0n1|/dev/sda|' archinstall/user_configuration.json > /tmp/machine.json
archinstall --config /tmp/machine.json --creds archinstall/user_credentials.json --dry-run
```

Common device names: `/dev/nvme0n1` (NVMe), `/dev/sda` (SATA), `/dev/vda` (VM).

If you *do* want to change the default permanently, `"device"` lives under
`disk_config.device_modifications[0]`, and it is the only place the disk is named.

The same trick works for the other per-machine values — `hostname` and `timezone`
are single keys near the top of the file.

### archinstall version note

Config schemas drift between archinstall releases. This file targets the archinstall
3.x schema. If your ISO's archinstall rejects it, run `archinstall` interactively once,
use its *Save configuration* option, and diff the result against this file.

## Public repo hygiene

Everything committed here is safe to publish:

- No hostnames, serial numbers, MAC addresses, or usernames.
- No passwords — credentials live in `archinstall/user_credentials.json`, which is
  gitignored; only the `.example.json` template is tracked.
- Machine-specific values are documented placeholders (`archbox`, `/dev/nvme0n1`).

Keep it that way: anything private goes in a gitignored path (`local/`, `secrets/`,
`*.local.conf`, `.env`) rather than in a tracked file.

## License

MIT — see [LICENSE](LICENSE).
