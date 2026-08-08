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
# dialogs, integrated terminal, etc. all work normally). git, the GitHub
# CLI (gh), and Claude Code are installed in the same container so VSCodium's
# source control and any terminal/agent workflows have them on PATH.
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
BUILD="2026.08.08-1"

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

# --- Claude Code apt repository --------------------------------------------
# Anthropic publishes signed apt/dnf/apk repositories, so Claude Code is
# installed the same signed-by way as the two repos above rather than through
# the `curl https://claude.ai/install.sh | bash` one-liner the docs lead with.
# A package manager install is the better fit here: it survives container
# rebuilds through this script, and it keeps the binary out of ~/.local/bin,
# which is bind-mounted from the host and would put a container-built binary
# on the HOST's PATH (same reasoning as the fd and distrobox shims below).
# Method and key fingerprint: https://code.claude.com/docs/en/setup
#
# The 'stable' channel is roughly a week behind 'latest' and skips releases
# with major regressions. To follow 'latest' instead, both the URL path and
# the suite name change: .../apt/latest latest main
#
# Unlike VSCodium and gh, upstream publishes the key's fingerprint, so verify
# it before trusting the key instead of relying on HTTPS alone. --with-colons
# is the machine-readable form; the human-readable output is spaced in groups
# of four and would need normalizing before it could be compared.
CLAUDE_KEYRING="/etc/apt/keyrings/claude-code.asc"
CLAUDE_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
if [ ! -f "$CLAUDE_KEYRING" ]; then
  echo "Installing the Claude Code signing key..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  CLAUDE_KEY_TMP="$(mktemp)"
  if wget -qO "$CLAUDE_KEY_TMP" https://downloads.claude.ai/keys/claude-code.asc; then
    if gpg --show-keys --with-colons "$CLAUDE_KEY_TMP" 2>/dev/null \
        | grep -q "^fpr:*${CLAUDE_FINGERPRINT}:"; then
      sudo install -m 0644 "$CLAUDE_KEY_TMP" "$CLAUDE_KEYRING"
    else
      echo "WARNING: Claude Code signing key did not match the expected fingerprint - refusing to install it. Everything else is unaffected."
    fi
  else
    echo "WARNING: could not download the Claude Code signing key - skipping Claude Code. Everything else is unaffected."
  fi
  rm -f "$CLAUDE_KEY_TMP"
fi
# Only register the repo if the key actually passed the gate above; a repo
# whose signed-by keyring is missing makes every later `apt-get update` fail.
if [ -f "$CLAUDE_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/claude-code.list ]; then
  echo "Registering the Claude Code apt repository..."
  echo "deb [signed-by=${CLAUDE_KEYRING}] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    | sudo tee /etc/apt/sources.list.d/claude-code.list >/dev/null
fi

echo "Installing/updating VSCodium, gh, and the lint toolchain..."
sudo apt-get update -qq
sudo apt-get install -y codium gh shellcheck jq fd-find yamllint

# Separate from the install above so a bad day at downloads.claude.ai can't
# take VSCodium itself down with it. apt installs of Claude Code do not
# self-update; re-running this script upgrades it along with everything else.
if [ -f /etc/apt/sources.list.d/claude-code.list ]; then
  echo "Installing/updating Claude Code..."
  sudo apt-get install -y claude-code \
    || echo "WARNING: could not install Claude Code. Everything else is unaffected."
fi

# Debian ships fd as 'fdfind' because the name 'fd' was already taken by
# another package. Nearly every fd example online says 'fd', so add the
# conventional alias. /usr/local/bin, not ~/.local/bin: $HOME is bind-mounted
# into the container and would leak this onto the HOST's PATH too (same
# reasoning as the distrobox shim below). Never clobber a real 'fd' binary.
if command -v fdfind >/dev/null 2>&1; then
  FD_SHIM="/usr/local/bin/fd"
  if [ -L "$FD_SHIM" ] || [ ! -e "$FD_SHIM" ]; then
    sudo ln -sf "$(command -v fdfind)" "$FD_SHIM"
  fi
fi

# --- actionlint -------------------------------------------------------------
# Debian 12 has no actionlint package, so install the upstream release binary.
# Unlike the apt repos above there is no signing key to pin against, so the
# trust anchor here is an explicit SHA-256 of the exact tarball. Do NOT switch
# this to a bare `curl | tar` or to "latest" - an unverified download of a
# binary that then lints your CI config is a poor trade.
#
# TO BUMP: pick the new version, then get its checksum from
#   https://github.com/rhysd/actionlint/releases/download/vX.Y.Z/actionlint_X.Y.Z_checksums.txt
ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256_amd64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ACTIONLINT_SHA256_arm64="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"

ACTIONLINT_ARCH="$(dpkg --print-architecture)"
case "$ACTIONLINT_ARCH" in
  amd64) ACTIONLINT_SHA256="$ACTIONLINT_SHA256_amd64" ;;
  arm64) ACTIONLINT_SHA256="$ACTIONLINT_SHA256_arm64" ;;
  *)     ACTIONLINT_SHA256="" ;;
esac

# Skip quietly if this arch has no pinned checksum, or if the pinned version is
# already installed. Re-runs of this script are meant to be cheap.
if [ -z "$ACTIONLINT_SHA256" ]; then
  echo "Note: no pinned actionlint checksum for architecture '${ACTIONLINT_ARCH}' - skipping actionlint."
elif [ "$(actionlint --version 2>/dev/null | head -n1)" = "$ACTIONLINT_VERSION" ]; then
  echo "actionlint ${ACTIONLINT_VERSION} already installed."
else
  echo "Installing actionlint ${ACTIONLINT_VERSION}..."
  ACTIONLINT_TMP="$(mktemp -d)"
  ACTIONLINT_TAR="actionlint_${ACTIONLINT_VERSION}_linux_${ACTIONLINT_ARCH}.tar.gz"
  if wget -qO "${ACTIONLINT_TMP}/${ACTIONLINT_TAR}" \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_TAR}"; then
    # Verify BEFORE unpacking, and bail out without installing on a mismatch.
    if printf '%s  %s\n' "$ACTIONLINT_SHA256" "${ACTIONLINT_TMP}/${ACTIONLINT_TAR}" \
        | sha256sum --check --status; then
      tar xzf "${ACTIONLINT_TMP}/${ACTIONLINT_TAR}" -C "$ACTIONLINT_TMP" actionlint
      sudo install -m 0755 "${ACTIONLINT_TMP}/actionlint" /usr/local/bin/actionlint
      echo "actionlint ${ACTIONLINT_VERSION} installed."
    else
      echo "WARNING: actionlint checksum mismatch - refusing to install it. Everything else is unaffected."
    fi
  else
    echo "WARNING: could not download actionlint - skipping it. Everything else is unaffected."
  fi
  rm -rf "$ACTIONLINT_TMP"
fi

# Symlink 'distrobox' -> distrobox-host-exec inside the container, so that
# running `distrobox ...` from VSCodium's integrated terminal (which is
# itself inside this container) forwards to the real host distrobox instead
# of silently doing nothing (this container has no podman/docker or socket
# access of its own). distrobox itself uses this same shim pattern for
# xdg-open, so it goes in /usr/local/bin, not ~/.local/bin - $HOME is bind-
# mounted into the container, so anything under ~/.local/bin would leak onto
# the HOST's PATH too and break the host's own real `distrobox` command.
# /usr/local/bin is part of the container's own (non-shared) filesystem.
# Only touch it if nothing's there yet, or if it's a symlink we created
# before - never clobber a real 'distrobox' binary.
DISTROBOX_HOST_EXEC="$(command -v distrobox-host-exec || true)"
if [ -n "$DISTROBOX_HOST_EXEC" ]; then
  DISTROBOX_SHIM="/usr/local/bin/distrobox"
  if [ -L "$DISTROBOX_SHIM" ] || [ ! -e "$DISTROBOX_SHIM" ]; then
    sudo ln -sf "$DISTROBOX_HOST_EXEC" "$DISTROBOX_SHIM"
    echo "Symlinked 'distrobox' -> distrobox-host-exec in /usr/local/bin (container-local)."
  else
    echo "Note: /usr/local/bin/distrobox already exists and isn't a symlink this script manages - leaving it alone."
  fi
fi

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
  # icon. Copy the real icon out of the container onto the host.
  #
  # Install it into the hicolor icon *theme* (by name, via the standard
  # ~/.local/share/icons/hicolor/<size>/apps layout) rather than pointing
  # Icon= at a raw absolute path. An absolute path works for the app-grid /
  # start-menu entry (Gio.AppInfo resolves either form), but most taskbars
  # and docks identify a running window via StartupWMClass, look up the
  # matching .desktop file, and then resolve its Icon *name* through the
  # icon theme - an absolute path doesn't resolve there, which is why the
  # icon showed up in the start menu but not the taskbar.
  local icon_theme_dir="$HOME/.local/share/icons/hicolor/512x512/apps"
  local host_icon="${icon_theme_dir}/vscodium.png"
  if distrobox enter "$CONTAINER_NAME" -- test -f /usr/share/pixmaps/vscodium.png 2>/dev/null; then
    mkdir -p "$icon_theme_dir"
    distrobox enter "$CONTAINER_NAME" -- cat /usr/share/pixmaps/vscodium.png > "$host_icon" 2>/dev/null || true
    if [ -s "$host_icon" ]; then
      sed -i -E "s#^Icon=.*#Icon=vscodium#" "$desktop_file"
      # Drop the old absolute-path copy an earlier version of this script left behind.
      rm -f "$HOME/.local/share/icons/vscodium.png"
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
  echo "git, gh, and Claude Code are installed inside the '$CONTAINER_NAME' container too."
  echo "Run 'claude' in VSCodium's terminal and log in on first use."
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
