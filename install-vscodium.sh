#!/usr/bin/env bash
#
# One-click installer/updater for VSCodium on immutable Fedora hosts
# (Bazzite, Silverblue, Kinoite, and similar) that can't install .deb/.rpm
# packages directly onto the base OS.
#
# How it works: this keeps a small Debian 12 Distrobox container, installs
# VSCodium from its official apt repository inside it, then uses
# `distrobox-export` to expose the app's .desktop entry on the host so it
# shows up in your app grid and runs like a native app (window, file
# dialogs, integrated terminal, etc. all work normally). git and the GitHub
# CLI (gh) are installed in the same container so VSCodium's source control
# and any terminal/agent workflows have them on PATH.
#
# This deliberately ships NO virtualization/Cowork tooling - VSCodium
# doesn't need it, so there is no QEMU/vhost_vsock anywhere in here.
#
# Usage:
#   ./install-vscodium.sh            install, or update if already installed
#   ./install-vscodium.sh --debug    same, but print every command run
#   ./install-vscodium.sh --remove   uninstall: drop the exported app + container
#   ./install-vscodium.sh --help     show this help
#
set -euo pipefail

# Bump this whenever the script's install logic changes. Only shown in
# --debug output, so you can tell which version produced a given log.
BUILD="2026.08.05-1"

CONTAINER_NAME="vscodium-box"
IMAGE="debian:12"

DEBUG=0
ACTION="install"

for arg in "$@"; do
  case "$arg" in
    --debug)
      DEBUG=1
      ;;
    --remove)
      ACTION="remove"
      ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (use --help)" >&2
      exit 1
      ;;
  esac
done

# --debug prints the build number once, then makes every command visible
# (set -x) instead of a separate custom logging function - it's the
# simplest way to give a full trace without maintaining two code paths.
if [ "$DEBUG" -eq 1 ]; then
  echo "[debug] install-vscodium.sh build $BUILD"
  set -x
fi

# Path to the temp script copied into the container; global (not function-
# local) so the cleanup trap below can still see it if a later command in
# do_install fails and exits the script early.
INNER_SCRIPT=""
trap 'rm -f "$INNER_SCRIPT"' EXIT

require_distrobox() {
  if ! command -v distrobox >/dev/null 2>&1; then
    echo "Error: distrobox is not installed or not on PATH." >&2
    echo "See https://github.com/89luca89/distrobox for install instructions." >&2
    exit 1
  fi
}

container_exists() {
  # `distrobox list` is the only stable cross-backend (podman/docker) way
  # to enumerate containers; match the NAME column between pipe delimiters
  # so we don't accidentally match a substring of another container's name.
  distrobox list 2>/dev/null | grep -qE "\| *${CONTAINER_NAME} *\|"
}

create_container() {
  echo "Creating distrobox container '$CONTAINER_NAME' ($IMAGE)..."
  distrobox create --yes --name "$CONTAINER_NAME" --image "$IMAGE"
}

# Everything below runs inside the container as one script. It's written to
# a file under $HOME (always bind-mounted into the container by distrobox)
# rather than passed inline, because quoting a multi-line apt/gpg script
# through `distrobox enter -- bash -c "..."` gets unreadable fast.
build_inner_script() {
  local out="$1"
  cat > "$out" <<'INNER'
set -euo pipefail

echo "Updating package lists..."
sudo apt-get update -qq

echo "Ensuring base tooling (curl, gnupg, wget, ca-certificates, git) is present..."
sudo apt-get install -y -qq curl gnupg wget ca-certificates git >/dev/null

# --- VSCodium apt repository -----------------------------------------------
# Official method from https://vscodium.com/ : pull the signing key, dearmor
# it into a dedicated keyring, and pin the repo to that keyring with
# signed-by. That pinning is the trust anchor - apt will refuse any package
# from this repo that isn't signed by exactly this key - so no separate
# fingerprint gate is needed here. Debian 12 uses the one-line .list format.
VSCODIUM_KEYRING="/usr/share/keyrings/vscodium-archive-keyring.gpg"
if [ ! -f "$VSCODIUM_KEYRING" ]; then
  echo "Installing the VSCodium signing key..."
  wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
    | gpg --dearmor \
    | sudo dd of="$VSCODIUM_KEYRING" status=none
fi
if [ ! -f /etc/apt/sources.list.d/vscodium.list ]; then
  echo "Registering the VSCodium apt repository..."
  echo "deb [arch=amd64,arm64 signed-by=${VSCODIUM_KEYRING}] https://download.vscodium.com/debs vscodium main" \
    | sudo tee /etc/apt/sources.list.d/vscodium.list >/dev/null
fi

# --- GitHub CLI (gh) apt repository ----------------------------------------
# Debian 12 doesn't carry gh in its own repos, so install it from GitHub's
# apt repo (official method from
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md). Same
# signed-by pinning model as above.
GH_KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
if [ ! -f "$GH_KEYRING" ]; then
  echo "Installing the GitHub CLI signing key..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO - https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of="$GH_KEYRING" status=none
  sudo chmod go+r "$GH_KEYRING"
fi
if [ ! -f /etc/apt/sources.list.d/github-cli.list ]; then
  echo "Registering the GitHub CLI apt repository..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=${GH_KEYRING}] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
fi

echo "Installing/updating VSCodium and gh..."
sudo apt-get update -qq
sudo apt-get install -y codium gh

echo "Exporting VSCodium to the host app menu..."
distrobox-export --app codium
INNER
}

# distrobox-export writes the .desktop file straight to the host (container
# and host share $HOME), so this runs after the container step, not inside it.
patch_launcher_flags() {
  local desktop_file="$HOME/.local/share/applications/${CONTAINER_NAME}-codium.desktop"
  if [ ! -f "$desktop_file" ]; then
    return 0
  fi

  # Disables Chromium GPU *compositing* only (not all acceleration) in the
  # exported launcher. VSCodium is an Electron app, and on this hybrid
  # Intel+NVIDIA hardware the same GPU-process repaint bug that affected
  # Claude Desktop shows up as garbled/ghosted text; disabling GPU
  # compositing clears it. If your VSCodium renders fine without this, delete
  # the "--disable-gpu-compositing" token from the Exec= line of the file
  # above (it'll be re-added next run - remove this sed line to stop that).
  #
  # Only touch the command after distrobox-enter's "--" separator, and only a
  # token that ends in "codium" (e.g. /usr/share/codium/codium) - never the
  # "-n vscodium-box" container name, which also contains "codium". This
  # matches both the main Exec= line and the "New Window" action's Exec=.
  sed -i -E '/^Exec=/ s#(--[[:space:]]+[^[:space:]]*codium)([[:space:]])#\1 --disable-gpu-compositing\2#' "$desktop_file"

  # Fix the icon. distrobox-export can't find VSCodium's icon (it lives in the
  # container's /usr/share/pixmaps, which - unlike $HOME - isn't shared with
  # the host), so it falls back to a hardcoded path to the generic Debian
  # icon. Copy the real icon out of the container onto the host, then point
  # every Icon= line at it by absolute path (absolute paths always resolve,
  # regardless of the host's icon-theme setup).
  local host_icon="$HOME/.local/share/icons/vscodium.png"
  if distrobox enter "$CONTAINER_NAME" -- test -f /usr/share/pixmaps/vscodium.png 2>/dev/null; then
    mkdir -p "$(dirname "$host_icon")"
    distrobox enter "$CONTAINER_NAME" -- cat /usr/share/pixmaps/vscodium.png > "$host_icon" 2>/dev/null || true
    if [ -s "$host_icon" ]; then
      sed -i -E "s#^Icon=.*#Icon=${host_icon}#" "$desktop_file"
    fi
  fi
}

do_install() {
  require_distrobox

  if container_exists; then
    echo "Container '$CONTAINER_NAME' already exists - updating VSCodium in place."
  else
    create_container
  fi

  INNER_SCRIPT="$(mktemp -p "$HOME" .vscodium-install-XXXXXX.sh)"
  build_inner_script "$INNER_SCRIPT"

  distrobox enter "$CONTAINER_NAME" -- bash "$INNER_SCRIPT"
  patch_launcher_flags

  echo
  echo "Done. VSCodium should now appear in your application launcher."
  echo "git and gh are installed inside the '$CONTAINER_NAME' container too."
  echo "Re-run this script any time to update it."
}

do_remove() {
  require_distrobox

  if ! container_exists; then
    echo "Container '$CONTAINER_NAME' doesn't exist - nothing to remove."
    exit 0
  fi

  echo "Removing exported app entry from the host..."
  distrobox enter "$CONTAINER_NAME" -- distrobox-export --app codium --delete || true

  echo "Deleting container '$CONTAINER_NAME'..."
  distrobox rm --force "$CONTAINER_NAME"

  echo "Done. VSCodium and its container have been removed."
}

case "$ACTION" in
  install) do_install ;;
  remove) do_remove ;;
esac
