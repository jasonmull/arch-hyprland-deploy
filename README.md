# arch-hyprland-deploy

Reusable, version-controlled deployment for **Arch Linux + Hyprland**. Clone it
onto a new machine and go from bare metal to a working desktop in two stages:

1. **Base OS** — an unattended [`archinstall`](#stage-1--base-install) config.
2. **Desktop** — [`install.sh`](#stage-2--desktop-setup) installs packages, stows
   dotfiles, and enables services. Idempotent, so re-run it whenever.

> **Building this for the first time?** The dotfiles here have not been run on a
> real machine yet. Work through **[BRINGUP.md](BRINGUP.md)** instead — it builds
> the desktop element by element with a verification checkpoint at each step, and
> ends by rewriting `install.sh` from what actually worked. Come back to the
> one-shot path once the repo reflects a machine you've booted.

> This repository is public. No hostnames, serials, usernames, or secrets are
> tracked — see [Public repo hygiene](#public-repo-hygiene).

## What you get

| Piece | Choice | Why |
| --- | --- | --- |
| Compositor | Hyprland | |
| Terminal | **ghostty** | In `[extra]` since 2025 — no AUR build needed |
| Launcher | **rofi 2.x** | Wayland support merged into mainline in 2.0.0; `rofi-wayland` is now a historical fork |
| Bar | **hyprpanel** | AUR (`hyprpanel-bin`); integrated panel rather than assembled parts |
| Notifications | **mako** | Small, Wayland-native, plain-ini config |
| Login | **greetd + tuigreet** | TTY-style greeter, no Qt/GTK stack, fast boot |
| Lock / idle | hyprlock + hypridle | First-party, configured here |
| Screenshots | grim + slurp + swappy | |
| Coding agent | **Claude Code** | Native installer, self-updating; user settings versioned here |
| Fonts | JetBrainsMono Nerd Font | Icon glyphs for the bar and terminal |

## Repository layout

```
archinstall/
  user_configuration.json        # unattended base install (tracked)
  user_credentials.example.json  # template (tracked)
  user_credentials.json          # your real credentials (gitignored)
  retarget.py                    # rewrites device + root size for a target disk
BRINGUP.md                       # manual, staged first-build order
install.sh                       # post-install setup, idempotent
pkglist-official.txt             # pacman packages
pkglist-aur.txt                  # yay packages (kept deliberately short)
hypr/.config/hypr/               # stow package -> ~/.config/hypr/
ghostty/.config/ghostty/         # stow package -> ~/.config/ghostty/
rofi/.config/rofi/               # stow package -> ~/.config/rofi/
mako/.config/mako/               # stow package -> ~/.config/mako/
scripts/.local/bin/              # stow package -> ~/.local/bin/
claude/.claude/settings.json     # stow package -> ~/.claude/settings.json
hosts/
  default/monitors.conf          # fallback layout: autoconfig
  example-laptop/monitors.conf   # copy these to hosts/<your-hostname>/
  example-desktop/monitors.conf
```

Each dotfile directory is a **stow package**: the path inside mirrors the path
under `$HOME`, so `hypr/.config/hypr/hyprland.conf` lands at
`~/.config/hypr/hyprland.conf`.

---

## Stage 1 — base install

Boot the Arch ISO, get networking up, then:

```bash
pacman -Sy git archinstall
git clone https://github.com/<you>/arch-hyprland-deploy /root/deploy
cd /root/deploy

# Generate password HASHES — archinstall stores hashes, not plaintext.
openssl passwd -6            # prompts, prints a hash; repeat for root

# Paste them in locally — this file is gitignored.
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

Drop `--silent` to get archinstall's menu with the config pre-loaded, so you can
eyeball everything before it commits.

### What the config sets

| Setting | Value |
| --- | --- |
| Bootloader | Limine |
| Filesystem | Btrfs with `compress=zstd,noatime` |
| Subvolumes | `@` → `/`, `@home` → `/home`, `@log` → `/var/log`, `@pkg` → `/var/cache/pacman/pkg` |
| Snapshots | Snapper |
| Partitioning | 1 GiB FAT32 ESP at `/boot`, rest of disk as Btrfs |
| Swap | enabled — **zram (zstd)**, not a swap partition |
| Audio | PipeWire |
| Network | NetworkManager |
| Timezone | `America/Chicago` |
| Locale / keymap | `en_US.UTF-8`, `us` |
| Kernel | `linux` |
| Hostname | `archlinux` (placeholder) |
| Schema | archinstall **4.4** |

`@log` and `@pkg` are separate subvolumes so that logs and the package cache are
excluded from snapshots — rolling back shouldn't rewind your journal or throw
away cached packages.

Stage-1 packages are deliberately minimal (`base-devel`, `git`, `sudo`, `vim`,
`openssh`). `git` matters: without it you can't clone this repo on the machine
you just installed.

Two things it deliberately does **not** set:

- **`gfx_driver` is null.** Fine for AMD/Intel — mesa arrives as a Hyprland
  dependency. **On NVIDIA you want it set**, along with the usual Hyprland
  NVIDIA environment variables, and finding that out at first login is painful.
- **`auth_config` is empty.** Users and passwords come from `--creds`; the
  install has no accounts without it.

Since swap is zram-only, there is no hibernation. That's usually right for a
desktop and a real decision on a laptop.

### Changing the target disk (do this on every new machine)

**archinstall has no percent unit.** Its `Unit` enum is `B`/`kB`/`MB`/`GB`/… ,
`KiB`/`MiB`/`GiB`/…, and `sectors`; `Size` has no percent handling. Partition
sizes are therefore absolute byte counts, and a tracked config cannot be
disk-agnostic — run it unchanged on a bigger disk and it silently leaves the
remainder unallocated. The disk *device* fails loudly; the disk *size* does not.

So don't hand-edit it. Check the device name, then let the script do the
arithmetic:

```bash
lsblk -dno NAME,SIZE,MODEL           # find the real device

./archinstall/retarget.py /dev/nvme0n1 -o /tmp/machine.json
```

It reads the disk's real size, rewrites the device path and the root partition
to fill it (reserving 1 MiB at the end for the GPT backup header), and writes a
new file — the tracked config stays clean. It refuses disks under ~9 GiB and
bails if the layout isn't the ESP + Btrfs pair it expects, rather than producing
a subtly wrong partition table.

```
device      /dev/nvme0n1
disk size       931.32 GiB
ESP               1.00 GiB  at 1 MiB
root            930.32 GiB  at 1.0010 GiB
reserved             1 MiB  (GPT backup header)
```

`--hostname` sets that too. `--disk-size-bytes` computes a layout for a disk
that isn't attached, so you can check the arithmetic before booting the ISO.

Then dry-run the result:

```bash
archinstall --config /tmp/machine.json \
            --creds archinstall/user_credentials.json --dry-run
```

Common device names: `/dev/nvme0n1` (NVMe), `/dev/sda` (SATA), `/dev/vda` (VM).

### Mirrors

`mirror_config` lists six HTTPS US mirrors. It's a starting point, not a
maintained list — mirrors go stale, and a saved ranking from today will be wrong
in six months. After install, regenerate properly:

```bash
sudo pacman -S reflector
sudo reflector --country US --age 12 --protocol https --sort rate \
               --save /etc/pacman.d/mirrorlist
```

### archinstall version note

This config is **derived from a real archinstall 4.4 save**, not written from
the docs — the schema, the `Size` object shape, and the Btrfs options are what
archinstall itself produced. That makes it considerably more trustworthy than
the 3.x-shaped config that preceded it, which used a `Percent` unit that does
not exist.

Schemas still drift between releases. If your ISO's archinstall rejects either
file, run it interactively once, use *Save configuration*, and diff the result
against these. That's also the fastest way to get a correct credentials file:
it writes the password hashes for you.

### After the install: verify Snapper snapshots boot

Limine plus Snapper needs the boot entries for snapshots to actually be
generated — usually `limine-snapper-sync` or the Limine mkinitcpio hook.
archinstall may not wire that up. Take a snapshot and confirm it appears in the
boot menu **before** you rely on rollback:

```bash
sudo snapper -c root create -d "test"
sudo snapper -c root list
```

---

## Stage 2 — desktop setup

Boot into the new system, log in as your user, then:

```bash
git clone https://github.com/<you>/arch-hyprland-deploy ~/deploy
cd ~/deploy
./install.sh --dry-run    # see exactly what it will do
./install.sh
```

What it does, in order:

1. Installs `base-devel`, `git`, `stow`.
2. Installs **yay** from the AUR if it is missing.
3. `pacman -S --needed` everything in `pkglist-official.txt`.
4. `yay -S --needed` everything in `pkglist-aur.txt`.
5. Installs **Claude Code** via Anthropic's native installer, if not present.
6. Backs up any conflicting real files to `~/.config-backup/<timestamp>/`, then
   stows every config package into `$HOME`.
7. Links `~/.config/hypr/monitors.conf` to this host's layout and creates an
   empty `~/.config/hypr/local.conf` if absent.
8. Enables `NetworkManager`, `bluetooth`, and `greetd`, and writes
   `/etc/greetd/config.toml` for tuigreet.

**It is idempotent.** Package installs use `--needed`, `stow --restow` reconciles
symlinks (clearing stale ones), services are checked before enabling, and
`local.conf` is never overwritten. Re-running it on a configured machine just
fixes drift.

```
./install.sh --skip-packages   # configs and services only
./install.sh --skip-services   # packages and configs only
./install.sh --dry-run         # print, change nothing
```

### Keybinds

`SUPER` is the mod key throughout. Ghostty deliberately uses `CTRL+SHIFT` for
everything so it never shadows a compositor binding.

| Key | Action |
| --- | --- |
| `SUPER+Return` | ghostty |
| `SUPER+Space` | rofi launcher |
| `SUPER+Tab` | window switcher across all workspaces |
| `SUPER+.` | emoji picker (bemoji) |
| `SUPER+Shift+V` | clipboard history |
| `SUPER+E` | file manager |
| `SUPER+Q` / `SUPER+F` / `SUPER+V` | close / fullscreen / float |
| `SUPER+1..0` | switch workspace (`+Shift` moves the window) |
| `SUPER+S` | scratchpad |
| `SUPER+L` | lock |
| `Print` | region → annotate in swappy |
| `Shift+Print` | region → clipboard |
| `Ctrl+Print` | full screen → `~/Pictures/Screenshots/` |

The window switcher is `scripts/.local/bin/hypr-window-switch`. rofi 2.x does have
a built-in `-show window` mode, but its reliability on Hyprland varies (it leans
on `wlr-foreign-toplevel` and has been reported to list only a subset of windows),
so the script asks `hyprctl` directly instead.

### HyprPanel configuration

**HyprPanel is not stowed, on purpose.** It writes its own config at runtime from
its settings GUI, and apps that save via write-temp-then-rename will replace a
symlink with a regular file — which silently detaches it from the repo. So it
owns `~/.config/hyprpanel/` outright.

To version your panel setup, copy it in once you like it:

```bash
mkdir -p hyprpanel && cp ~/.config/hyprpanel/config.json hyprpanel/
git add hyprpanel/config.json && git commit -m "Save hyprpanel config"
```

and to restore it on a new machine:

```bash
mkdir -p ~/.config/hyprpanel && cp hyprpanel/config.json ~/.config/hyprpanel/
```

The filename has moved between HyprPanel versions (`options.json` in older
releases, `config.json` in newer ones) — check what is actually in
`~/.config/hyprpanel/` after first launch.

### Claude Code

`install.sh` installs it with Anthropic's native installer:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

That puts a launcher at `~/.local/bin/claude` pointing into
`~/.local/share/claude/versions/`, and it **updates itself in the background** —
so unlike every other package here, later `install.sh` runs skip it entirely
once `claude` is on PATH. Sign in by running `claude` once; `claude doctor`
prints install health and validates your settings file without starting a
session.

Alternatives, if you'd rather not curl-pipe-bash on a fresh box:

| Method | Command | Trade-off |
| --- | --- | --- |
| Native (used here) | `curl -fsSL https://claude.ai/install.sh \| bash` | Official, auto-updates. Outside pacman |
| Native, stable channel | `curl -fsSL https://claude.ai/install.sh \| bash -s stable` | ~1 week behind, skips releases with major regressions |
| AUR | `yay -S claude-code` | pacman-managed, but community-maintained and auto-update is disabled |
| npm | `npm install -g @anthropic-ai/claude-code` | Needs Node 22+; manual updates |

Anthropic publishes signed apt/dnf/apk repos but **no pacman repo**, so on Arch
the native installer is the official path. Releases from 2.1.89 on ship a
GPG-signed `manifest.json` if you want to verify the binary before trusting it.

#### What is and isn't tracked

Only `claude/.claude/settings.json` is committed — a near-empty starting point
that denies reads of `.env` files:

```json
{
  "permissions": {
    "allow": [],
    "deny": ["Read(./.env)", "Read(./.env.*)"]
  }
}
```

Everything else Claude Code writes to `~/.claude/` is credentials, session
history, and per-project state, and is gitignored via `claude/.claude/*` with a
negation for `settings.json`. **Never put secrets in the `env` block of a
tracked settings file** — that is the one key in this repo where a
`.gitignore` will not save you, since the file itself is committed.

Settings precedence, highest first: managed → `claude --settings` → project
`.claude/settings.local.json` → project `.claude/settings.json` → user
`~/.claude/settings.json` (the one this repo stows). So per-project settings
always win over the versioned defaults, and `settings.local.json` — which
Claude Code adds to your global git excludes itself — is where machine-specific
or private overrides belong.

`install.sh` creates `~/.claude/` as a real directory before stowing, for the
same reason it does with `~/.config/hypr`: a folded directory symlink would send
your credentials and session history into the repo.

---

## Adding a new machine

**Use the per-host directory. Don't reach for chezmoi-style templating.**

Create a directory named after the machine's hostname and put its monitor layout
in it:

```bash
mkdir -p hosts/$(hostnamectl --static)
hyprctl monitors                                     # get connector names/modes
cp hosts/example-laptop/monitors.conf hosts/$(hostnamectl --static)/
$EDITOR hosts/$(hostnamectl --static)/monitors.conf
./install.sh --skip-packages                         # relink
```

`install.sh` symlinks `~/.config/hypr/monitors.conf` to `hosts/<hostname>/` when
that directory exists, and falls back to `hosts/default/monitors.conf`
(`monitor = , preferred, auto, auto`) when it doesn't. A brand-new machine
therefore works before you've configured anything.

Three layers, in precedence order:

| Layer | Where | Tracked? |
| --- | --- | --- |
| Shared baseline | `hypr/.config/hypr/hyprland.conf` | yes |
| Per-host | `hosts/<hostname>/monitors.conf` | yes (your call) |
| This machine only | `~/.config/hypr/local.conf` | **no** — gitignored |

`hyprland.conf` sources the last two at the end, so they win.

### Why not templating?

chezmoi-style templating solves a problem this repo doesn't have. It's the right
tool when many files need *small* per-machine substitutions — a username threaded
through a dozen configs, secrets from a password manager, one file that differs by
three lines across five hosts. Here, essentially one file differs per machine
(monitor layout), and it differs *completely* rather than by a token or two.

The concrete costs of templating for this repo:

- Every config stops being a valid config. You can't `hyprctl reload` a `.tmpl`
  or let the editor syntax-check it; you have to render first.
- It adds chezmoi as a hard dependency on the bare-metal path, right where you
  want the fewest moving parts.
- Debugging becomes two-layer: is the desktop broken, or did the template render
  wrong?

A plain directory of real config files keeps every file directly readable,
diffable, and testable, and the fallback means an unconfigured host still boots
to a working desktop. Reach for templating if you later find yourself
substituting the *same* value into many files — that's the signal you've
outgrown this.

---

## Public repo hygiene

Everything committed here is safe to publish:

- No hostnames, serial numbers, MAC addresses, or usernames.
- No passwords. Credentials live in `archinstall/user_credentials.json`, which is
  gitignored; only the `.example.json` template is tracked.
- `/etc/greetd/config.toml` embeds a username, so it is **generated by
  `install.sh`**, never tracked.
- Machine-specific values are documented placeholders (`archbox`, `/dev/nvme0n1`).

Keep it that way. Anything private belongs in a gitignored path:

| Path | Use |
| --- | --- |
| `~/.config/hypr/local.conf` | machine-only Hyprland overrides |
| `~/.claude/`, `.claude/settings.local.json` | Claude Code credentials, state, private overrides |
| `local/`, `secrets/` | anything else machine-specific |
| `*.local.conf`, `*.local.json` | local variants of tracked files |
| `.env`, `*.key`, `*.pem`, `id_*` | keys and tokens |

If you'd rather not publish your real hostnames, skip `hosts/<hostname>/`
entirely and keep the layout in `~/.config/hypr/local.conf` instead — the
fallback in `hosts/default/` covers the rest.

Before the first push, it's worth a look at what you're about to publish:

```bash
git ls-files | xargs grep -rniE "$(hostnamectl --static)|$(id -un)" || echo "clean"
```

## License

MIT — see [LICENSE](LICENSE).
