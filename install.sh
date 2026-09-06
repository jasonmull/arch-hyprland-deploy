#!/usr/bin/env bash
#
# arch-hyprland-deploy - post-install setup.
#
# Run this as your normal user (NOT root) on a freshly installed Arch system:
#     ./install.sh
#
# It is idempotent: every step checks before it acts, so re-running it on a
# machine that is already set up is a no-op that just reconciles drift.
#
# Flags:
#     --skip-packages   configs and services only
#     --skip-services   packages and configs only
#     --dry-run         print what would happen, change nothing

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STOW_PACKAGES=(hypr ghostty rofi mako scripts)
BACKUP_DIR="${HOME}/.config-backup/$(date +%Y%m%d-%H%M%S)"

SKIP_PACKAGES=0
SKIP_SERVICES=0
DRY_RUN=0

# --- output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
    C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

step() { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '  %s*%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

run() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"
    else
        "$@"
    fi
}

# --- argument parsing --------------------------------------------------------
while (( $# )); do
    case "$1" in
        --skip-packages) SKIP_PACKAGES=1 ;;
        --skip-services) SKIP_SERVICES=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)               die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# --- sanity checks -----------------------------------------------------------
(( EUID != 0 )) || die "run this as your normal user, not root - it stows into \$HOME"
command -v pacman >/dev/null || die "pacman not found; this script is for Arch Linux"
[[ -f "${REPO_DIR}/pkglist-official.txt" ]] || die "run this from inside the repo"

if (( DRY_RUN )); then
    warn "dry run - nothing will be installed or modified"
fi

# Read a package list: strip comments (inline and whole-line) and blanks.
read_pkglist() {
    sed -e 's/#.*//' -e 's/[[:space:]]\+//g' "$1" | grep -v '^$' || true
}

# ============================================================================
# 1. Packages
# ============================================================================
if (( SKIP_PACKAGES )); then
    step "Packages (skipped)"
else
    step "Prerequisites"
    # Everything else depends on these three existing first.
    run sudo pacman -S --needed --noconfirm base-devel git stow
    ok "base-devel, git, stow"

    step "AUR helper (yay)"
    if command -v yay >/dev/null; then
        ok "yay already installed"
    elif (( DRY_RUN )); then
        printf '  %s[dry-run]%s build and install yay from the AUR\n' "$C_YELLOW" "$C_OFF"
    else
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
        ( cd "$tmp/yay-bin" && makepkg -si --noconfirm )
        rm -rf "$tmp"
        trap - EXIT
        ok "yay installed"
    fi

    step "Official repository packages"
    mapfile -t official < <(read_pkglist "${REPO_DIR}/pkglist-official.txt")
    (( ${#official[@]} )) || die "pkglist-official.txt is empty"
    # --needed makes this a no-op for anything already present.
    run sudo pacman -S --needed --noconfirm -- "${official[@]}"
    ok "${#official[@]} packages reconciled"

    step "AUR packages"
    mapfile -t aur < <(read_pkglist "${REPO_DIR}/pkglist-aur.txt")
    if (( ${#aur[@]} )); then
        if command -v yay >/dev/null || (( DRY_RUN )); then
            run yay -S --needed --noconfirm -- "${aur[@]}"
            ok "${#aur[@]} AUR packages reconciled"
        else
            warn "yay unavailable, skipping: ${aur[*]}"
        fi
    else
        ok "no AUR packages listed"
    fi
fi

# ============================================================================
# 2. Dotfiles via GNU Stow
# ============================================================================
step "Dotfiles"

# Create the target directories up front. Without this, stow "folds" a whole
# package into a single directory symlink (~/.config/hypr -> repo), and then
# per-host files written into that directory would land inside the repo.
run mkdir -p "${HOME}/.config"/{hypr,ghostty,rofi,mako} \
             "${HOME}/.local/bin" \
             "${HOME}/Pictures/Screenshots" \
             "${HOME}/Pictures/wallpapers"

# Move aside any real file that would block a symlink. Existing symlinks are
# left alone - those are ours from a previous run, and stow will restow them.
conflicts=0
for pkg in "${STOW_PACKAGES[@]}"; do
    [[ -d "${REPO_DIR}/${pkg}" ]] || die "missing stow package: ${pkg}"
    while IFS= read -r -d '' src; do
        rel="${src#"${REPO_DIR}/${pkg}/"}"
        dst="${HOME}/${rel}"
        if [[ -e "$dst" && ! -L "$dst" ]]; then
            run mkdir -p "$(dirname "${BACKUP_DIR}/${rel}")"
            run mv "$dst" "${BACKUP_DIR}/${rel}"
            warn "backed up existing ${rel}"
            conflicts=$((conflicts + 1))
        fi
    done < <(find "${REPO_DIR}/${pkg}" -type f -print0)
done
(( conflicts )) && warn "originals saved under ${BACKUP_DIR}"

# --restow makes this idempotent: it unlinks then relinks, clearing stale
# links from configs that have since been renamed or removed.
# --no-folding forces file-level symlinks instead of directory symlinks.
run stow --dir "${REPO_DIR}" --target "${HOME}" --restow --no-folding \
         -- "${STOW_PACKAGES[@]}"
ok "stowed: ${STOW_PACKAGES[*]}"

# ============================================================================
# 3. Per-host configuration
# ============================================================================
step "Per-host configuration"

host="$(hostnamectl --static 2>/dev/null || hostname)"
host_dir="${REPO_DIR}/hosts/${host}"
if [[ -f "${host_dir}/monitors.conf" ]]; then
    ok "using hosts/${host}/monitors.conf"
else
    host_dir="${REPO_DIR}/hosts/default"
    warn "no hosts/${host}/ directory - falling back to hosts/default/"
    warn "create hosts/${host}/monitors.conf to pin this machine's layout"
fi

# Symlinked, not copied, so edits in the repo take effect on the next reload.
run ln -sfn "${host_dir}/monitors.conf" "${HOME}/.config/hypr/monitors.conf"
# shellcheck disable=SC2088  # literal tilde in user-facing output
ok "~/.config/hypr/monitors.conf -> ${host_dir#"${REPO_DIR}/"}/monitors.conf"

# hyprland.conf unconditionally sources local.conf, and Hyprland errors on a
# missing source. Create an empty one so a machine with no overrides is clean.
if [[ -e "${HOME}/.config/hypr/local.conf" ]]; then
        # shellcheck disable=SC2088  # literal tilde in user-facing output
ok "~/.config/hypr/local.conf exists (left untouched)"
elif (( DRY_RUN )); then
    printf '  %s[dry-run]%s create ~/.config/hypr/local.conf\n' "$C_YELLOW" "$C_OFF"
else
    cat > "${HOME}/.config/hypr/local.conf" <<'LOCAL'
# Machine-local Hyprland overrides. NOT tracked by git - this file is created
# by install.sh and never overwritten.
#
# Sourced last, so anything here wins over hyprland.conf. Good candidates:
# device-specific input tweaks, a nonstandard keyboard layout, an env var that
# only this box needs.
#
# Examples:
#   $terminal = kitty
#   input { kb_options = ctrl:nocaps }
#   env = LIBVA_DRIVER_NAME,nvidia
LOCAL
    ok "created ~/.config/hypr/local.conf"
fi

# ============================================================================
# 4. System services
# ============================================================================
if (( SKIP_SERVICES )); then
    step "Services (skipped)"
else
    step "System services"

    unit_exists() {
        systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .
    }

    enable_unit() {
        local unit="$1"
        if ! unit_exists "$unit"; then
            warn "${unit} not installed, skipping"
        elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            ok "${unit} already enabled"
        else
            run sudo systemctl enable --now "$unit"
            ok "enabled ${unit}"
        fi
    }

    enable_unit NetworkManager.service
    enable_unit bluetooth.service

    # --- greetd + tuigreet ---------------------------------------------------
    # Written here rather than tracked in the repo because it embeds a username,
    # and this repository is public.
    if ! unit_exists greetd.service; then
        warn "greetd not installed, skipping login manager setup"
    else
        current_dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
        if [[ -n "$current_dm" && "$current_dm" != *greetd* ]]; then
            warn "another display manager is active: $(basename "$current_dm")"
            warn "leaving it alone - disable it first if you want greetd"
        else
            if [[ -f /etc/greetd/config.toml ]] && grep -q tuigreet /etc/greetd/config.toml; then
                ok "/etc/greetd/config.toml already configured for tuigreet"
            elif (( DRY_RUN )); then
                printf '  %s[dry-run]%s write /etc/greetd/config.toml\n' "$C_YELLOW" "$C_OFF"
            else
                if [[ -f /etc/greetd/config.toml ]]; then
                    sudo cp /etc/greetd/config.toml /etc/greetd/config.toml.bak
                    warn "existing config saved to /etc/greetd/config.toml.bak"
                fi
                sudo mkdir -p /etc/greetd
                sudo tee /etc/greetd/config.toml >/dev/null <<GREETD
# Written by arch-hyprland-deploy/install.sh
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --cmd Hyprland"
user = "greeter"
GREETD
                ok "wrote /etc/greetd/config.toml for user $(id -un)"
            fi
            # Enabled but not started: --now here would kill the current session.
            if systemctl is-enabled --quiet greetd.service 2>/dev/null; then
                ok "greetd.service already enabled"
            else
                run sudo systemctl enable greetd.service
                ok "enabled greetd.service (takes effect on next boot)"
            fi
        fi
    fi

    # --- user services -------------------------------------------------------
    # PipeWire and wireplumber are socket-activated and need no enabling.
    if systemctl --user list-unit-files --no-legend hyprpolkitagent.service 2>/dev/null | grep -q .; then
        if systemctl --user is-enabled --quiet hyprpolkitagent.service 2>/dev/null; then
            ok "hyprpolkitagent.service already enabled"
        else
            run systemctl --user enable hyprpolkitagent.service
            ok "enabled hyprpolkitagent.service"
        fi
    fi
fi

# ============================================================================
# Done
# ============================================================================
step "Done"
cat <<SUMMARY

  Next steps:

    1. Reboot, or start Hyprland from a TTY, to pick up greetd.
    2. HyprPanel writes its own config on first launch. Once you have it
       looking right, copy it into this repo to version it:
         cp ~/.config/hyprpanel/config.json hyprpanel/
       (See the HyprPanel section of the README.)
    3. Drop a wallpaper at ~/Pictures/wallpapers/wall.png.
    4. Pin this machine's monitor layout:
         mkdir -p hosts/\$(hostnamectl --static)
         hyprctl monitors            # read the connector names
         \$EDITOR hosts/\$(hostnamectl --static)/monitors.conf

  Re-run this script any time - it is idempotent.

SUMMARY
