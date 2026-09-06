# Manual bring-up order

Build the desktop by hand, one element at a time, then harvest what works into
this repo. `install.sh` gets rewritten at the end from what you actually did —
it should be a transcript of a working build, not a guess at one.

Every config file in this repo is currently **unexecuted**. Treat them as
starting points to adapt, not as known-good.

## Why this order

Three rules drive it:

1. **Dependencies first.** Session environment before anything that relies on
   it; a working compositor before anything that draws inside it.
2. **Escape hatches stay open.** The login manager and the screen locker — the
   two things that can lock you out — go last, after you know the rest works.
3. **One suspect at a time.** Add one element, verify it, commit it. When
   something breaks, the cause is whatever you just did.

## Rules that apply throughout

- **Keep a second TTY free.** `Ctrl+Alt+F2` gets you a text login from anywhere.
  This is your way out of a broken compositor, locker, or greeter. Know it
  before you need it.
- **Run every command in a terminal before you bind it to a key.** A keybind
  that silently does nothing is far harder to debug than a command that prints
  an error. This one habit would have caught most of the bugs in this repo.
- **Harvest after each stage.** When an element works, move its config into the
  matching stow package here, `stow` it, confirm it still works through the
  symlink, and commit. The repo grows as a record of a working system.
- **Install in small groups.** Resist `pacman -S` with a long list. The package
  list in `pkglist-official.txt` is a shopping list, not an install order.

---

## Stage 0 — Validate the base install in a VM

Do this before touching real hardware. `archinstall/user_configuration.json`
wipes a disk and has never been run.

```bash
qemu-img create -f qcow2 arch-test.qcow2 40G
qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \
  -drive file=arch-test.qcow2,format=qcow2 \
  -cdrom archlinux.iso -boot d \
  -bios /usr/share/ovmf/x64/OVMF.fd     # UEFI: required for systemd-boot
```

Inside the VM, the disk will be `/dev/vda`, not `/dev/nvme0n1` — use the `sed`
override from the README. Generate password hashes with `openssl passwd -6`.

**Verify:** `--dry-run` is accepted, then a real install completes and the VM
reboots to a login prompt.

**Harvest:** fix whatever the schema rejected. This is the one artifact worth
getting right *before* bare metal, because the failure mode is a wiped disk.

---

## Stage 1 — Base OS on real hardware

Run archinstall with the config you just validated. Nothing else yet.

**Verify:**

```bash
lsblk                          # partition layout is what you expected
ping -c3 archlinux.org         # NetworkManager brought the link up
sudo -v                        # your user has sudo
free -h                        # zram swap is present
bootctl status                 # systemd-boot installed
```

You should be at a TTY. That is the correct place to be — no desktop yet.

---

## Stage 2 — Fonts, then compositor and terminal

Fonts first: the terminal and bar configs reference a Nerd Font, and a missing
font shows up as blank boxes that look like a config bug.

```bash
sudo pacman -S --needed ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
sudo pacman -S --needed hyprland ghostty
```

**The gotcha:** Hyprland writes a default `~/.config/hypr/hyprland.conf` on
first launch, and that default binds the terminal to **kitty**, which you don't
have. Launch it once, then switch to a TTY with `Ctrl+Alt+F2` and edit
`$terminal = ghostty` before you go looking for a terminal that will never open.

```bash
Hyprland                       # from the TTY, launched by hand — no greeter yet
```

**Verify:** you get a desktop. `SUPER+Q` closes a window, `SUPER+RETURN` opens
ghostty, `SUPER+M` exits back to the TTY.

**Harvest:** nothing yet — keep running Hyprland's default config a little
longer. Adopting this repo's `hyprland.conf` now would reintroduce every
unverified line at once.

---

## Stage 3 — Session environment (the uwsm decision)

Do this *before* anything that runs as a systemd user service. Everything
downstream — the polkit agent, portals, hyprpanel — depends on getting it right,
and diagnosing it later means re-testing all of them.

From inside a Hyprland session:

```bash
systemctl --user show-environment | grep -E 'WAYLAND_DISPLAY|XDG_CURRENT_DESKTOP'
```

- **Both present** → systemd user services can see your compositor. Move on.
- **Empty or missing** → user services will start but fail to connect. Fix it
  now, one of two ways:

```bash
# Option A (current Hyprland recommendation): launch the session via uwsm
sudo pacman -S --needed uwsm
uwsm start hyprland-uwsm.desktop     # replaces bare `Hyprland` from here on

# Option B (older, smaller change): keep launching Hyprland directly, and add
# to hyprland.conf:
#   exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
```

**Verify:** re-run the `show-environment` check and see both variables.

**Harvest:** record which option you chose — it determines the greetd command
in stage 11 and whether `uwsm` belongs in `pkglist-official.txt`.

---

## Stage 4 — Portals and polkit

```bash
sudo pacman -S --needed xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
                        hyprpolkitagent qt5-wayland qt6-wayland
systemctl --user start hyprpolkitagent
```

**Verify:**

```bash
systemctl --user status xdg-desktop-portal-hyprland   # active
systemctl --user status hyprpolkitagent               # active, not failed
```

Then trigger a real auth prompt — a graphical password dialog should appear:

```bash
pkexec true
```

If nothing appears, stage 3 is wrong. Go back; don't work around it.

---

## Stage 5 — Audio

PipeWire came from archinstall, so this is mostly verification.

```bash
sudo pacman -S --needed wireplumber pavucontrol
wpctl status                   # sinks and sources listed
```

**Verify:** play something. `pavucontrol` opens and shows the stream.

---

## Stage 6 — Network and bluetooth applets

```bash
sudo pacman -S --needed network-manager-applet bluez bluez-utils blueman
sudo systemctl enable --now bluetooth
```

**Verify:** `bluetoothctl show` reports a controller. Run `nm-applet` and
`blueman-applet` by hand — they won't have a tray to sit in until stage 7, so
just confirm they start without error.

---

## Stage 7 — The bar (hyprpanel)

First an AUR helper, since this is the first AUR package:

```bash
sudo pacman -S --needed base-devel git
git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si
```

Then the panel. This is the heaviest dependency chain in the build — expect it
to pull in the ags/astal stack:

```bash
yay -S hyprpanel-bin
hyprpanel                      # run in the foreground first, watch for errors
```

**Verify:** the bar appears. The tray picks up `nm-applet` and
`blueman-applet` from stage 6.

**Harvest — and settle an open question:** find where hyprpanel actually wrote
its config (`config.json` and `options.json` have both been used across
versions):

```bash
ls -la ~/.config/hyprpanel/
```

Copy it into `hyprpanel/` here and update the README with the real filename.
Do **not** stow it — hyprpanel rewrites this file from its own settings GUI, and
a write-then-rename would replace your symlink with a regular file.

---

## Stage 8 — Launcher (rofi)

```bash
sudo pacman -S --needed rofi
rofi -show drun                # from a terminal, unthemed, before any binding
```

**Verify:** it opens, finds apps, launches one. Confirm it is rofi 2.x
(`rofi -version`) — Wayland support only landed in mainline at 2.0.0.

Then theme it: copy `rofi/.config/rofi/config.rasi` from this repo to
`~/.config/rofi/`, and re-run `rofi -show drun` **after every edit**. rofi
refuses to start on an invalid keybinding or property — that is exactly how the
`kb-cancel` bug in this repo would have surfaced in about ten seconds.

Only once it looks right, add the keybind.

---

## Stage 9 — Notifications (mako)

```bash
sudo pacman -S --needed mako libnotify
mako &
notify-send "test" "does this appear"
```

**Verify:** the notification appears. Then adapt `mako/.config/mako/config`,
and `makoctl reload` after each edit.

---

## Stage 10 — Utilities, then keybinds

Install the tools, and test **every one from a terminal** before it becomes a
keybind:

```bash
sudo pacman -S --needed grim slurp swappy wl-clipboard cliphist \
                        brightnessctl playerctl jq thunar

grim -g "$(slurp)" - | swappy -f -      # region screenshot
grim -g "$(slurp)" - | wl-copy          # region to clipboard
brightnessctl set 5%-                   # backlight
playerctl play-pause                    # media keys
wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
```

Anything that fails here fails silently as a keybind.

**Now** adopt this repo's `hyprland.conf` — but incrementally. Paste in a
section at a time (`input`, then `general`/`decoration`, then window rules, then
binds), running `hyprctl reload` after each. `hyprctl reload` prints config
errors; a keybind that does nothing does not.

The window switcher needs `jq`, already installed above:

```bash
./scripts/.local/bin/hypr-window-switch     # run directly before binding to SUPER+Tab
```

**Harvest:** this is the big one. Once the whole config is in and reloads
cleanly, move it into `hypr/.config/hypr/`, `stow hypr`, and confirm it still
reloads through the symlink.

---

## Stage 11 — Screen lock and idle (careful)

`hyprlock` can lock you out of your own session. Test it with a second TTY
already open and logged in, so you can `pkill hyprlock` if the unlock path is
broken.

```bash
sudo pacman -S --needed hyprlock hypridle
hyprlock                       # with Ctrl+Alt+F2 escape route ready
```

**Verify:** it locks, your password unlocks it. Only then add hypridle, and only
then add the `SUPER+L` bind and the `exec-once`.

Set the hypridle timeouts long while testing — a 30-second lock loop while
you're still editing configs is miserable.

---

## Stage 12 — Login manager (last)

Everything above was launched by hand from a TTY, which is the debuggable path.
Only now hand that job to a greeter.

```bash
sudo pacman -S --needed greetd greetd-tuigreet
sudo vim /etc/greetd/config.toml
```

The session command depends on your stage 3 decision:

```toml
[terminal]
vt = 1

[default_session]
# If you chose uwsm in stage 3:
command = "tuigreet --time --remember --cmd 'uwsm start hyprland-uwsm.desktop'"
# If you chose to launch Hyprland directly:
# command = "tuigreet --time --remember --cmd Hyprland"
user = "greeter"
```

```bash
sudo systemctl enable greetd          # NOT --now; that kills your session
sudo reboot
```

**If it fails to boot into a greeter:** `Ctrl+Alt+F2`, log in,
`sudo systemctl disable greetd`, reboot. That is your rollback.

---

## Stage 13 — Claude Code

Independent of everything else; a leaf. Do it whenever.

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude                         # sign in
claude doctor                  # validates install and settings
```

---

## Stage 14 — Per-host monitor layout

Now that you can see the outputs:

```bash
hyprctl monitors               # real connector names, modes, refresh rates
mkdir -p hosts/$(hostnamectl --static)
cp hosts/example-laptop/monitors.conf hosts/$(hostnamectl --static)/
$EDITOR hosts/$(hostnamectl --static)/monitors.conf
```

---

## Stage 15 — Write install.sh from what you did

Only now. You know the real package list, the real order, the real session
command, and where hyprpanel keeps its config.

- Rebuild `pkglist-official.txt` from `pacman -Qqe` — but **curate it**, don't
  dump it. Compare against what you installed above and drop anything that came
  along as a dependency.
- Fold the stage order into `install.sh`. The existing script's stow, backup,
  and per-host logic is tested and worth keeping; the package list and service
  setup are what change.
- Re-run `install.sh --dry-run`, then run it on a *second* machine or a fresh
  VM. A deployment script that has only ever run on the machine it was written
  from is still a hypothesis.
