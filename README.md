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
| Bootloader | systemd-boot |
| Filesystem | ext4 root |
| Partitioning | 1 GiB FAT32 ESP at `/boot`, rest of disk as ext4 `/` |
| Swap | enabled — **zram**, not a swap partition |
| Audio | PipeWire |
| Network | NetworkManager |
| Timezone | `America/Chicago` |
| Locale / keymap | `en_US.UTF-8`, `us` |
| Kernel | `linux` |
| Hostname | `archbox` (placeholder) |

Stage-1 packages are deliberately minimal (`base-devel`, `git`, `sudo`, `vim`,
`openssh`) — the desktop is stage 2's job.

### Changing the target disk (do this on every new machine)

The config ships with a **placeholder disk of `/dev/nvme0n1`**. It is the single
most machine-specific value in the file, and installing to the wrong device will
wipe it. Check the real name first:

```bash
lsblk -dno NAME,SIZE,MODEL
```

Then override it **without editing the tracked file**, so `git status` stays clean:

```bash
sed 's|/dev/nvme0n1|/dev/sda|' archinstall/user_configuration.json > /tmp/machine.json
archinstall --config /tmp/machine.json --creds archinstall/user_credentials.json --dry-run
```

Common names: `/dev/nvme0n1` (NVMe), `/dev/sda` (SATA), `/dev/vda` (VM). To change
the default permanently, `"device"` lives under
`disk_config.device_modifications[0]` and is the only place the disk is named.
`hostname` and `timezone` are single keys near the top of the same file.

### archinstall version note

Config schemas drift between archinstall releases, and **neither JSON file here
has been validated against a live ISO** — they target the archinstall 3.x schema
as documented upstream. Treat the `--dry-run` above as required, not optional.

If your ISO's archinstall rejects either file, run `archinstall` interactively
once, use *Save configuration*, and diff the result against these files. That is
also the fastest way to get a correctly-shaped credentials file: it writes the
password hashes for you.

The disk layout in particular uses `{"unit": "Percent", "value": 100}` for the
root partition's size, which is the shape most likely to have drifted.

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
