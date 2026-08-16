#!/usr/bin/env bash
#
# Uninstaller for VSCodium on immutable Fedora hosts, matching
# install-vscodium.sh. Removes the vscodium-box container, the host-side
# launcher and .desktop entry, and any leftovers from older versions of this
# project (including the pre-podman Distrobox setup).
#
# What is left behind on purpose:
#   - the directory you passed to --repos-dir (your code)
#   - the container's private home at ~/.local/state/vscodium-box/home
#     (settings, extensions, dotfiles, Claude Code auth)
#   - the saved repos-dir path at ~/.config/vscodium-box/repos-dir
# Delete those yourself if you want a completely clean slate; this script
# tells you where they are.
#
# Usage:
#   ./uninstall-vscodium.sh            remove the container, launcher and
#                                        .desktop entry
#   ./uninstall-vscodium.sh --debug    same, but print every command run
#   ./uninstall-vscodium.sh --help     show this help
#
set -euo pipefail

# Bump this whenever the script's removal logic changes. Only shown in
# --debug output, so you can tell which version produced a given log.
BUILD="2026.08.16-1"

CONTAINER_NAME="vscodium-box"

CONTAINER_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/vscodium-box/home"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vscodium-box"

WRAPPER="$HOME/.local/bin/${CONTAINER_NAME}"
DESKTOP_FILE="$HOME/.local/share/applications/${CONTAINER_NAME}.desktop"
WRAPPER_CONSOLE="$HOME/.local/bin/${CONTAINER_NAME}-console"
DESKTOP_FILE_CONSOLE="$HOME/.local/share/applications/${CONTAINER_NAME}-console.desktop"
WRAPPER_RESTART="$HOME/.local/bin/${CONTAINER_NAME}-restart"
DESKTOP_FILE_RESTART="$HOME/.local/share/applications/${CONTAINER_NAME}-restart.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/512x512/apps/vscodium.png"

DEBUG=0

die() {
  echo "Error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

if [ "$DEBUG" -eq 1 ]; then
  echo "[debug] uninstall-vscodium.sh build $BUILD"
  set -x
fi

require_podman() {
  # /run/.containerenv exists in podman containers, /.dockerenv in docker ones.
  if [ -f /run/.containerenv ] || [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    die "this looks like it's running inside a container. Run it from a host terminal instead."
  fi
  command -v podman >/dev/null 2>&1 \
    || die "podman is not installed or not on PATH. See https://podman.io/docs/installation"
}

require_podman

if podman container exists "$CONTAINER_NAME"; then
  echo "Deleting container '$CONTAINER_NAME'..."
  podman rm --force "$CONTAINER_NAME" >/dev/null
else
  echo "Container '$CONTAINER_NAME' doesn't exist - nothing to delete."
fi

echo "Removing the launcher and app entries from the host..."
rm -f "$WRAPPER" "$DESKTOP_FILE" "$WRAPPER_CONSOLE" "$DESKTOP_FILE_CONSOLE" \
  "$WRAPPER_RESTART" "$DESKTOP_FILE_RESTART" "$ICON_FILE"
# Leftovers from the Distrobox-based versions of this script (pre-2.0.0).
rm -f "$HOME/.local/share/applications/${CONTAINER_NAME}-codium.desktop"
rm -f "$HOME/.local/share/icons/vscodium.png"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

echo
echo "Done. VSCodium and its container have been removed."
echo "Your repos were only ever mounted at --repos-dir and are untouched."
if [ -d "$CONTAINER_HOME" ]; then
  echo "The container's own settings/extensions/dotfiles are still on disk at:"
  echo "  $CONTAINER_HOME"
  echo "Delete that directory yourself if you want a completely clean slate."
fi
if [ -f "$CONFIG_DIR/repos-dir" ]; then
  echo "Your saved --repos-dir path is still on disk at:"
  echo "  $CONFIG_DIR/repos-dir"
fi
