#!/usr/bin/env bash
#
# One-click installer/updater for VSCodium on immutable Fedora hosts
# (Bazzite, Silverblue, Kinoite, and similar) that can't install .deb/.rpm
# packages directly onto the base OS.
#
# How it works: this keeps a small Debian 12 container, managed with rootless
# podman, installs VSCodium from its official apt repository inside it, and
# writes a launcher plus a .desktop entry on the host so it shows up in your
# app grid and runs like a native app. git, the GitHub CLI (gh), the lint
# toolchain, and DeepSeek Harness are installed in the same container, so
# VSCodium's source control and any terminal/agent workflows have them on PATH.
# Claude Code is available too, but only if you pass --claude - see below.
#
# WHAT THE CONTAINER CAN REACH ON THE HOST - this is the whole point of the
# script, so it is stated exactly. The bind mounts, plus /dev/dri if present,
# plus the NVIDIA GPU if the host has the Container Toolkit's CDI spec, and
# nothing else:
#
#   1. the directory you pass to --repos-dir, read-write
#   2. the container's own private home (settings, extensions, dotfiles,
#      DeepSeek Harness / Claude Code auth), which lives under ~/.local/state
#      and is used by nothing else on the host
#   3. the X11 socket (XWayland), read-only, so a window can be drawn. Native
#      Wayland is available via --wayland but is not the default - see the
#      Wayland note in README.md
#   4. /dev/dri, for GPU-accelerated rendering, if the host has one and
#      --no-gpu was not passed
#   5. the NVIDIA GPU, if /dev/nvidiactl and the Container Toolkit's CDI spec
#      for nvidia.com/gpu (/etc/cdi/nvidia.yaml) exist and --no-cuda was not
#      passed. The whole GPU is exposed - every /dev/nvidia* node, NVML, and
#      the driver libraries via the CDI hook (nvidia-smi, libcuda, libnvml all
#      appear inside the box, no in-container driver install). This powers the
#      CUDA LLM runtimes provisioned inside it. Needs one host-side SELinux
#      rule (ensure_nvidia_selinux_module) - see the CUDA node in README.md.
#
# It does NOT get your host home directory, the host filesystem, host /tmp,
# other host devices, host processes, or the host D-Bus session. It is not
# privileged and SELinux confinement stays on.
#
# This deliberately does NOT use distrobox, which an earlier version of this
# script did. distrobox always bind-mounts the host $HOME at its real path and
# always mounts all of / at /run/host, in a --privileged container with SELinux
# and AppArmor confinement disabled. Its own documentation says the --home flag
# "will NOT prevent the mount of the host's home directory", and no --unshare-*
# flag removes /run/host. There is no way to get repo-scoped access out of it.
# See docs/usage/distrobox-create.md and
# pkg/containermanager/providers/podman.go in github.com/89luca89/distrobox.
#
# Things you give up compared to the old distrobox setup, all documented in
# README.md: no `distrobox` command from the integrated terminal, no host
# browser/notifications/portals (no D-Bus), and no host access to ports you
# serve inside the box unless you pass --publish.
#
# Run this from a HOST terminal, not from VSCodium's integrated terminal - the
# container has no path back to the host any more.
#
# Usage:
#   ./install-vscodium.sh --repos-dir DIR   install, scoping container access
#                                            to DIR (e.g. ~/github); required
#                                            the first time
#   ./install-vscodium.sh                   update if already installed, or
#                                            reuse a previously saved --repos-dir
#   ./install-vscodium.sh --wayland         use native Wayland instead of
#                                            XWayland (creation only). Off by
#                                            default: it crashes on some hosts,
#                                            see the Wayland note in README.md
#   ./install-vscodium.sh --no-gpu          force software rendering even if
#                                            /dev/dri is available (creation
#                                            only)
#   ./install-vscodium.sh --no-cuda         do not expose the NVIDIA GPU to the
#                                            container, even if one is present
#                                            (creation only). CUDA is on by
#                                            default when /dev/nvidiactl and a
#                                            nvidia.com/gpu CDI spec exist
#   ./install-vscodium.sh --no-llm          skip provisioning the CUDA LLM
#                                            runtimes (vLLM/Ollama/llama.cpp)
#                                            and the CUDA toolkit inside the box
#   ./install-vscodium.sh --publish PORT    publish a container port on the
#                                            host loopback (creation only,
#                                            repeatable)
#   ./install-vscodium.sh --claude          also install Claude Code. Off by
#                                            default - DeepSeek Harness is
#                                            installed either way
#   ./install-vscodium.sh --no-wm-harnesses skip installing the MarkLLM /
#                                            reverse-SynthID watermark
#                                            backends. On by default - both are
#                                            installed unless you pass this
#   ./install-vscodium.sh --debug           same, but print every command run
#   ./install-vscodium.sh --help            show this help
#
# To uninstall, run ./uninstall-vscodium.sh instead.
#
set -euo pipefail

# Bump this whenever the script's install logic changes. Only shown in --debug
# output, so you can tell which version produced a given log.
BUILD="2026.08.16-3"

CONTAINER_NAME="vscodium-box"
IMAGE="debian:12"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION_SCRIPT="${SCRIPT_DIR}/provision-container.sh"
# SELinux allow module for the NVIDIA device nodes - see selinux/ in this repo
# and ensure_nvidia_selinux_module below.
SELINUX_TE="${SCRIPT_DIR}/selinux/vscodium-box-nvidia.te"

# $HOME on ostree systems is usually /home/<user>, a symlink to /var/home/<user>.
# podman needs the real path for mount sources, and the checks below compare
# canonical paths, so resolve it once here.
HOME_REAL="$(realpath -e "$HOME")"

# The container's private home (settings, dotfiles, extensions, DeepSeek
# Harness / Claude Code auth). Mounted into the container at the same path the
# host home has, so that `~` and absolute paths behave normally inside - but
# the contents are this directory, not your host home.
CONTAINER_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/vscodium-box/home"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vscodium-box"
CONFIG_FILE="${CONFIG_DIR}/repos-dir"

# Host-side files this script writes. None of these are reachable from inside
# the container, which is what stops a process in there from rewriting the
# launcher you click on.
WRAPPER="$HOME/.local/bin/${CONTAINER_NAME}"
DESKTOP_FILE="$HOME/.local/share/applications/${CONTAINER_NAME}.desktop"
# A second launcher/desktop pair for a raw shell in the container - no
# VSCodium, no GPU flags. See write_console_launcher below.
WRAPPER_CONSOLE="$HOME/.local/bin/${CONTAINER_NAME}-console"
DESKTOP_FILE_CONSOLE="$HOME/.local/share/applications/${CONTAINER_NAME}-console.desktop"
# A third launcher/desktop pair that restarts the container. See
# write_restart_launcher below.
WRAPPER_RESTART="$HOME/.local/bin/${CONTAINER_NAME}-restart"
DESKTOP_FILE_RESTART="$HOME/.local/share/applications/${CONTAINER_NAME}-restart.desktop"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
ICON_FILE="${ICON_DIR}/vscodium.png"

# Defaults: XWayland + GPU passthrough (if a GPU is present). Native Wayland
# is opt-in via --wayland - on this host it crashes deterministically inside
# Electron's zwp_linux_dmabuf_v1 handling against KWin 6.7's compositor
# (upstream Electron/Chromium bug, not something a mount flag can fix), so
# XWayland is the mode that actually works and is now the default.
DEBUG=0
REPOS_DIR=""
USE_GPU=1
USE_X11=1
GPU_FLAG_GIVEN=0
X11_FLAG_GIVEN=0
PUBLISH_PORTS=()
WITH_CLAUDE=0
# NVIDIA CUDA passthrough: on by default when the host has the NVIDIA Container
# Toolkit's CDI spec for nvidia.com/gpu. Opt out with --no-cuda. Creation-only.
USE_CUDA=1
CUDA_FLAG_GIVEN=0
CUDA_ACTIVE=0
# Provision the CUDA LLM runtimes (vLLM/Ollama/llama.cpp) and the CUDA toolkit
# inside the box. On by default; opt out with --no-llm (it is a multi-GB
# install, so keeping the choice explicit matters).
WITH_LLM=1
# Same-scheme watermark backends for the watermarks-remover service: on by
# default (MarkLLM + reverse-SynthID), opt-out with --no-wm-harnesses.
WITH_WM_HARNESSES=1

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
    --gpu)
      # Already the default; accepted so old habits/scripts don't break.
      USE_GPU=1
      GPU_FLAG_GIVEN=1
      shift
      ;;
    --no-gpu)
      USE_GPU=0
      GPU_FLAG_GIVEN=1
      shift
      ;;
    --cuda)
      # Already the default on NVIDIA hosts; accepted so it can be stated
      # explicitly and so re-runs make the intent visible.
      USE_CUDA=1
      CUDA_FLAG_GIVEN=1
      shift
      ;;
    --no-cuda)
      USE_CUDA=0
      CUDA_FLAG_GIVEN=1
      shift
      ;;
    --x11)
      # Already the default; accepted so old habits/scripts don't break.
      USE_X11=1
      X11_FLAG_GIVEN=1
      shift
      ;;
    --wayland)
      USE_X11=0
      X11_FLAG_GIVEN=1
      shift
      ;;
    --publish)
      [ -n "${2:-}" ] || die "--publish requires a port number."
      PUBLISH_PORTS+=("$2")
      shift 2
      ;;
    --publish=*)
      PUBLISH_PORTS+=("${1#*=}")
      shift
      ;;
    --claude)
      WITH_CLAUDE=1
      shift
      ;;
    --wm-harnesses)
      # Already the default; accepted so old habits/scripts don't break.
      WITH_WM_HARNESSES=1
      shift
      ;;
    --no-wm-harnesses)
      WITH_WM_HARNESSES=0
      shift
      ;;
    --llm)
      # Already the default; accepted so old habits/scripts don't break.
      WITH_LLM=1
      shift
      ;;
    --no-llm)
      WITH_LLM=0
      shift
      ;;
    --repos-dir)
      REPOS_DIR="${2:-}"
      [ -n "$REPOS_DIR" ] || die "--repos-dir requires a path argument."
      shift 2
      ;;
    --repos-dir=*)
      REPOS_DIR="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,73p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

# --debug prints the build number once, then makes every command visible
# (set -x) instead of a separate custom logging function - it's the simplest
# way to give a full trace without maintaining two code paths.
if [ "$DEBUG" -eq 1 ]; then
  echo "[debug] install-vscodium.sh build $BUILD"
  set -x
fi

require_podman() {
  # /run/.containerenv exists in podman containers, /.dockerenv in docker ones.
  # Catch this early: the old distrobox setup let you run this script from
  # VSCodium's own terminal, and that no longer works by design.
  if [ -f /run/.containerenv ] || [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    die "this looks like it's running inside a container. Run it from a host terminal instead."
  fi
  command -v podman >/dev/null 2>&1 \
    || die "podman is not installed or not on PATH. See https://podman.io/docs/installation"
  [ -f "$PROVISION_SCRIPT" ] \
    || die "provision-container.sh not found next to this script (looked in $SCRIPT_DIR)."
}

container_exists() {
  podman container exists "$CONTAINER_NAME"
}

# Refuse to touch a container left over from the distrobox era. It has the same
# name but a completely different (wide open) mount set, and it holds the user's
# old settings, so deleting it silently would be wrong.
check_legacy_container() {
  local manager
  manager="$(podman inspect "$CONTAINER_NAME" \
    --format '{{index .Config.Labels "manager"}}' 2>/dev/null || true)"
  if [ "$manager" = "distrobox" ]; then
    echo "The existing '$CONTAINER_NAME' container was created by distrobox, which gave it" >&2
    echo "your whole home directory and the host filesystem. This script no longer manages" >&2
    echo "containers like that. To move over:" >&2
    echo >&2
    echo "  ./uninstall-vscodium.sh" >&2
    echo "  $0 --repos-dir DIR" >&2
    echo >&2
    echo "Your old VSCodium settings and extensions lived in that container's home and are" >&2
    echo "removed with it; the new container starts with a fresh, private home." >&2
    exit 1
  fi
}

# Validates a candidate repos directory and echoes its canonical path. Used for
# both the --repos-dir argument and whatever is read back out of the config
# file, because that file lives on disk between runs and is not trusted input.
validate_repos_dir() {
  local candidate="$1" canon

  # ':' and ',' are field separators in a podman --volume argument; a path
  # containing either could turn one mount into something quite different.
  case "$candidate" in
    *:*|*,*) die "repos dir must not contain ':' or ',': $candidate" ;;
  esac
  [ -d "$candidate" ] || die "repos dir is not a directory: $candidate"

  # realpath resolves symlinks and '..', so the checks below can't be dodged
  # with either. A symlinked repos dir is fine; what gets mounted is its target.
  canon="$(realpath -e "$candidate")" || die "cannot resolve repos dir: $candidate"

  case "$canon" in
    /|/home|/var/home|/root|/etc|/usr|/var|/tmp)
      die "refusing to mount '$canon' into the container." ;;
  esac
  [ "$canon" != "$HOME_REAL" ] \
    || die "refusing to mount your whole home directory. Pick a subdirectory, e.g. ~/github"
  case "$canon/" in
    "$HOME_REAL"/*) ;;
    *) die "repos dir must live under $HOME (got: $canon)" ;;
  esac

  printf '%s\n' "$canon"
}

save_repos_dir() {
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$1" > "$CONFIG_FILE"
}

# Refuses to use the saved repos dir unless the file it came from is safe:
# another local user with write access to it could otherwise point the next
# run's mount wherever they liked. (The container itself cannot reach this path
# at all - that is the point of where these files live.)
#
# This is a separate function from the read below because `die` inside a command
# substitution would only kill the subshell, and the caller would carry on with
# an empty value as though the file simply wasn't there.
check_config_file_safe() {
  local mode
  [ ! -L "$CONFIG_FILE" ] || die "$CONFIG_FILE is a symlink - refusing to read it."
  [ -O "$CONFIG_FILE" ] || die "$CONFIG_FILE is not owned by you - refusing to read it."
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  # Last two digits are group and other; anything writable there is a no.
  case "$mode" in
    *[2367]?|*[2367]) die "$CONFIG_FILE is group- or world-writable (mode $mode) - refusing to read it. chmod 600 it." ;;
  esac
}

# Echoes the first line of the config file, so a file with trailing junk appended
# to it cannot smuggle anything in.
read_saved_repos_dir() {
  local line
  IFS= read -r line < "$CONFIG_FILE" || true
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# Fills in REPOS_DIR from --repos-dir if given (and persists it for next time),
# else from the saved config, else fails with instructions.
resolve_repos_dir() {
  local saved
  if [ -n "$REPOS_DIR" ]; then
    REPOS_DIR="$(validate_repos_dir "$REPOS_DIR")" || exit 1
    save_repos_dir "$REPOS_DIR"
    return
  fi
  if [ -f "$CONFIG_FILE" ]; then
    check_config_file_safe
    if saved="$(read_saved_repos_dir)"; then
      REPOS_DIR="$(validate_repos_dir "$saved")" || exit 1
      return
    fi
  fi
  echo "Error: no repos directory known yet. Pass --repos-dir DIR (e.g. --repos-dir ~/github)" >&2
  echo "the first time you run this script. It's the only folder of yours the container" >&2
  echo "will be able to see." >&2
  exit 1
}

# Returns success when the host can hand the whole NVIDIA GPU to the container:
# the control device exists AND the NVIDIA Container Toolkit has generated a CDI
# spec, which is what lets podman inject the device nodes and the driver
# libraries via `--device nvidia.com/gpu=all`. A real NVIDIA GPU present but no
# CDI spec means the toolkit isn't configured yet - that is "not available" so
# the installer can tell you exactly what to fix rather than silently omitting
# it.
nvidia_cuda_available() {
  { [ -c /dev/nvidiactl ] || [ -e /dev/nvidiactl ]; } \
    && { [ -f /etc/cdi/nvidia.yaml ] || [ -f /var/run/cdi/nvidia.yaml ]; }
}

# Installs (or refreshes) the targeted SELinux allow rule that lets the
# container's process domain use the NVIDIA device nodes. The nodes are labeled
# xserver_misc_device_t by systemd-udev, and container_t is denied that type -
# absent this rule, CUDA/NVML inside the box fail with "Insufficient
# Permissions" even though every device node is present. See the .te file and
# the CUDA node in README.md.
#
# This is the one host-side change this feature needs, and it follows the same
# precedent as the Wayland connectto rule in README.md: best-effort via sudo at
# install time, with the exact manual commands printed when sudo is unavailable
# (this box's sudo prompts for a password, so the attempt is always non-root
# aware and never hangs a non-interactive run). It is non-fatal on every path:
# a host that declines the rule simply won't get GPU access, and the rest of the
# install carries on.
ensure_nvidia_selinux_module() {
  # checkmodule requires the policy module name to match the base of the output
  # .mod filename, so the temp files must be named after the module (not random
  # mktemp names), or checkmodule fails its own name check and we'd print a
  # bogus "could not compile" message.
  local mod="/tmp/vscodium-box-nvidia.mod" pp="/tmp/vscodium-box-nvidia.pp" rc=0
  [ "$CUDA_ACTIVE" -eq 1 ] || return 0
  [ -f "$SELINUX_TE" ] || { echo "Note: $SELINUX_TE missing - cannot install the NVIDIA SELinux rule. CUDA inside the box will fail with 'Insufficient Permissions'."; return 0; }
  if ! command -v checkmodule >/dev/null 2>&1 || ! command -v semodule_package >/dev/null 2>&1; then
    echo "Note: SELinux policy tooling (checkmodule/semodule_package) is not installed here, so the NVIDIA allow rule cannot be installed automatically."
    echo "  To enable GPU inside the box later, run:"
    echo "    sudo checkmodule -M -m -o /tmp/vscodium-box-nvidia.mod $SELINUX_TE"
    echo "    sudo semodule_package -o /tmp/vscodium-box-nvidia.pp -m /tmp/vscodium-box-nvidia.mod"
    echo "    sudo semodule -i /tmp/vscodium-box-nvidia.pp"
    return 0
  fi
  checkmodule -M -m -o "$mod" "$SELINUX_TE" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    semodule_package -o "$pp" -m "$mod" 2>/dev/null || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    if sudo -n semodule -i "$pp" 2>/dev/null; then
      echo "Installed the NVIDIA SELinux allow rule (vscodium-box-nvidia) - the box can now use the GPU."
    else
      echo "Note: could not install the NVIDIA SELinux allow rule non-interactively (sudo needs a password here)."
      echo "  The box will be unable to use the GPU until you run:"
      echo "    sudo checkmodule -M -m -o /tmp/vscodium-box-nvidia.mod $SELINUX_TE"
      echo "    sudo semodule_package -o /tmp/vscodium-box-nvidia.pp -m /tmp/vscodium-box-nvidia.mod"
      echo "    sudo semodule -i /tmp/vscodium-box-nvidia.pp"
    fi
  else
    echo "Note: could not compile the NVIDIA SELinux allow rule (checkmodule failed). See $SELINUX_TE."
  fi
  rm -f "$mod" "$pp"
}

create_container() {
  local uid gid user wayland_sock create_args port

  uid="$(id -u)"
  gid="$(id -g)"
  user="$(id -un)"

  echo "Creating container '$CONTAINER_NAME' ($IMAGE)..."
  echo "Scoping container filesystem access to: $REPOS_DIR"
  mkdir -p "$CONTAINER_HOME"
  chmod 0700 "$CONTAINER_HOME"

  # The mount and namespace set below IS the security contract. Read it as a
  # list of what the container gets, and assume anything not listed is denied.
  #
  # Deliberately absent: --privileged, --security-opt label=disable, --pid host,
  # --ipc host, --network host, /dev, /sys, /run/host, host /tmp, and the D-Bus
  # session socket. podman defaults to a private PID namespace, a private IPC
  # namespace and a private network namespace, so those need no flag.
  create_args=(
    --name "$CONTAINER_NAME"
    --hostname "$CONTAINER_NAME"
    # keep-id maps your host uid to the same uid inside, so files written into
    # the repos mount keep the right ownership on the host side.
    --userns keep-id
    --user "${uid}:${gid}"
    # podman's default /dev/shm is 64MB, which Chromium/Electron renderers
    # routinely exhaust and then crash on.
    --shm-size 512m
    # ',z' relabels the mount for SELinux, which is Enforcing on these hosts;
    # without it a container_t process cannot read your user_home_t files. 'z'
    # (shared) rather than 'Z' (private), so host tools keep working on the
    # same files.
    --volume "${CONTAINER_HOME}:${HOME_REAL}:rw,z"
    --volume "${REPOS_DIR}:${REPOS_DIR}:rw,z"
    --env "HOME=${HOME_REAL}"
    --env "XDG_RUNTIME_DIR=/run/user/${uid}"
    --env "USER=${user}"
  )

  if [ "$USE_X11" -eq 1 ]; then
    # XWayland fallback for when Electron won't start on Wayland. Only the one
    # socket is exposed, read-only.
    local display_num="${DISPLAY##*:}"
    display_num="${display_num%%.*}"
    [ -S "/tmp/.X11-unix/X${display_num}" ] \
      || die "no X11 socket at /tmp/.X11-unix/X${display_num} (DISPLAY=${DISPLAY:-unset})."
    create_args+=(
      # ',z' relabels for SELinux - see the matching comment on the Wayland
      # socket mount below.
      --volume "/tmp/.X11-unix/X${display_num}:/tmp/.X11-unix/X${display_num}:ro,z"
      --env "DISPLAY=:${display_num}"
    )
    if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
      create_args+=(
        --volume "${XAUTHORITY}:/run/user/${uid}/.Xauthority:ro,z"
        --env "XAUTHORITY=/run/user/${uid}/.Xauthority"
      )
    fi
  else
    [ -n "${WAYLAND_DISPLAY:-}" ] \
      || die "WAYLAND_DISPLAY is not set - run this from your desktop session, or pass --x11."
    wayland_sock="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/${WAYLAND_DISPLAY}"
    [ -S "$wayland_sock" ] || die "no Wayland socket at $wayland_sock."
    create_args+=(
      # ',z' relabels the socket for SELinux, same as the other two mounts -
      # without it container_t can't read the compositor's socket, Electron
      # silently falls back to X11 (which isn't there either), and exits with
      # no window and no error visible outside --debug.
      --volume "${wayland_sock}:/run/user/${uid}/${WAYLAND_DISPLAY}:ro,z"
      --env "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
      # Tells Electron to use its Wayland backend rather than defaulting to X11.
      --env "ELECTRON_OZONE_PLATFORM_HINT=wayland"
    )
  fi

  if [ "$USE_GPU" -eq 1 ]; then
    if [ -d /dev/dri ]; then
      create_args+=(--device /dev/dri)
    elif [ "$GPU_FLAG_GIVEN" -eq 1 ]; then
      die "--gpu was passed but /dev/dri does not exist on this host."
    fi
    # else: GPU passthrough is on by default but there's no /dev/dri to pass -
    # fall back to software rendering silently instead of failing every plain
    # install on a host with no GPU device.
  fi

  if [ "$USE_CUDA" -eq 1 ]; then
    if nvidia_cuda_available; then
      # CDI injection hands over the whole GPU: every /dev/nvidia* node plus
      # the driver libraries (NVML, libcuda, nvidia-smi) via the Container
      # Toolkit's CDI hook. No --privileged, no label=disable - the other
      # scoping holds; only the NVML access above is added by
      # ensure_nvidia_selinux_module. The CDI spec also carries the /dev/dri
      # device the toolkit found, so both compute and graphics come through
      # in one flag.
      create_args+=(--device nvidia.com/gpu=all)
      CUDA_ACTIVE=1
      echo "NVIDIA GPU found - exposing it and the CUDA driver to the container (nvidia.com/gpu)."
    elif [ "$CUDA_FLAG_GIVEN" -eq 1 ]; then
      die "--cuda was passed but the host has no usable NVIDIA CDI setup (need /dev/nvidiactl and /etc/cdi/nvidia.yaml, typically via the nvidia-container-toolkit). Install the toolkit and run 'sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml', or pass --no-cuda."
    else
      echo "Note: no CUDA-capable NVIDIA setup detected (/dev/nvidiactl + nvidia.com/gpu CDI spec missing) - skipping GPU passthrough and the CUDA LLM runtimes."
      WITH_LLM=0
    fi
  fi

  # Loopback only, never 0.0.0.0: publishing a dev server to the whole network
  # is not something an install script should do behind your back.
  for port in ${PUBLISH_PORTS+"${PUBLISH_PORTS[@]}"}; do
    case "$port" in
      *[!0-9]*) die "--publish takes a port number, got: $port" ;;
    esac
    create_args+=(--publish "127.0.0.1:${port}:${port}")
  done

  echo "Relabeling mounts for SELinux - on a large repos directory this can take a moment..."
  # 'sleep infinity' just keeps the container alive; the launcher runs VSCodium
  # with `podman exec` against it.
  podman create "${create_args[@]}" "$IMAGE" sleep infinity >/dev/null
}

provision_container() {
  echo "Provisioning the container (this is the slow part on a first run)..."
  podman start "$CONTAINER_NAME" >/dev/null
  podman exec --interactive --user root \
    --env "BOX_USER=$(id -un)" \
    --env "BOX_UID=$(id -u)" \
    --env "BOX_GID=$(id -g)" \
    --env "BOX_HOME=${HOME_REAL}" \
    --env "BOX_DEBUG=${DEBUG}" \
    --env "BOX_WITH_CLAUDE=${WITH_CLAUDE}" \
    --env "BOX_WITH_WM_HARNESSES=${WITH_WM_HARNESSES}" \
    --env "BOX_WITH_CUDA=${CUDA_ACTIVE}" \
    --env "BOX_WITH_LLM=${WITH_LLM}" \
    "$CONTAINER_NAME" bash -s < "$PROVISION_SCRIPT"
}

# Reads back the env vars podman recorded at container-creation time and
# re-emits the subset a launcher needs, quoted for embedding in a generated
# script. Shared by write_launcher and write_console_launcher, so both
# launchers stay in sync with how the container was actually created rather
# than with this run's flags - a plain update run doesn't repeat --gpu/--x11.
#
# Passed explicitly instead of relying on `podman exec` inheriting what
# `podman create --env` set: podman's exec documentation does not promise that
# inheritance, and a launcher that silently loses WAYLAND_DISPLAY just fails to
# open a window (or, for the console launcher, silently loses HOME).
compute_env_args() {
  local env_args="" name value line
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    case "$name" in
      HOME|USER|XDG_RUNTIME_DIR|WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|ELECTRON_OZONE_PLATFORM_HINT)
        env_args+=" --env $(printf '%q' "${name}=${value}")"
        ;;
    esac
  done < <(podman inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}')
  # Force a UTF-8 locale on every session this launcher starts. The container's
  # own env is not guaranteed to set it (provision-container.sh sets it only for
  # interactive bash, via /etc/bash.bashrc), yet the release skills' G7 ASCII
  # lint needs a UTF locale for grep to accept its `\x{...}` classes above the
  # BMP - hence LANG/LC_ALL on the exec, downstream of everything here.
  env_args+=" --env LANG=C.UTF-8 --env LC_ALL=C.UTF-8"
  printf '%s' "$env_args"
}

# Replaces what distrobox-export used to do. Generating the launcher and the
# .desktop entry outright is simpler than patching whatever a tool emitted, and
# both files now live somewhere the container cannot write to.
write_launcher() {
  local gpu_flags="--disable-gpu-compositing"
  local env_args
  env_args="$(compute_env_args)"

  # Without /dev/dri there is no GPU to use at all, so ask Electron for software
  # rendering directly instead of letting it probe and fail.
  #
  # --disable-gpu-compositing is kept in both cases: on this hybrid
  # Intel+NVIDIA hardware the GPU-process repaint bug shows up as garbled or
  # ghosted text, and disabling GPU *compositing* (not all acceleration) clears
  # it. If your VSCodium renders fine without it, drop the flag from the Exec
  # line in the launcher below; it is re-added on the next run of this script.
  if ! podman exec "$CONTAINER_NAME" test -d /dev/dri 2>/dev/null; then
    gpu_flags="--disable-gpu --disable-gpu-compositing"
  fi

  mkdir -p "$(dirname "$WRAPPER")" "$(dirname "$DESKTOP_FILE")"

  cat > "$WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
# Generated by install-vscodium.sh (build ${BUILD}) - edits are overwritten on
# the next run. Starts the ${CONTAINER_NAME} container if needed, then runs
# VSCodium inside it.
set -euo pipefail
podman start ${CONTAINER_NAME} >/dev/null
exec podman exec --interactive${env_args} ${CONTAINER_NAME} \\
  /usr/bin/codium ${gpu_flags} "\$@"
WRAPPER_EOF
  chmod 0755 "$WRAPPER"

  cat > "$DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=VSCodium
GenericName=Text Editor
Comment=Code editing, running in the ${CONTAINER_NAME} container
Exec=${WRAPPER} %F
Icon=vscodium
Terminal=false
Categories=Utility;TextEditor;Development;IDE;
MimeType=text/plain;inode/directory;
StartupNotify=true
StartupWMClass=VSCodium
Keywords=vscode;codium;
DESKTOP_EOF
  chmod 0644 "$DESKTOP_FILE"

  # Install the icon into the hicolor icon *theme* (by name, via the standard
  # ~/.local/share/icons/hicolor/<size>/apps layout) rather than pointing Icon=
  # at a raw absolute path. An absolute path works for the app-grid entry
  # (Gio.AppInfo resolves either form), but most taskbars and docks identify a
  # running window via StartupWMClass, look up the matching .desktop file, and
  # then resolve its Icon *name* through the icon theme - an absolute path
  # doesn't resolve there, which is why the icon used to show up in the start
  # menu but not the taskbar.
  mkdir -p "$ICON_DIR"
  if podman cp "${CONTAINER_NAME}:/usr/share/pixmaps/vscodium.png" "$ICON_FILE" 2>/dev/null; then
    :
  else
    echo "Note: could not copy VSCodium's icon out of the container - the launcher will use a fallback icon."
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  fi
}

# A second launcher/desktop pair for a raw shell in the container: no
# VSCodium, no GPU flags, just `podman exec` into a login bash. Useful for
# checking what a CLI tool installed inside the container actually sees
# (env vars, PATH, mounts) without going through the editor's integrated
# terminal.
#
# Icon=utilities-terminal is a standard icon-theme name (not something this
# script installs, unlike vscodium.png above), and Terminal=true is what makes
# this work without hardcoding a specific terminal emulator: it tells whatever
# desktop environment reads the .desktop file to run Exec= inside the user's
# own default terminal, per the freedesktop Desktop Entry Specification. That
# terminal is what allocates the tty, which is why the wrapper below can just
# ask podman for one (--tty) rather than launching a terminal emulator itself.
write_console_launcher() {
  local env_args
  env_args="$(compute_env_args)"

  cat > "$WRAPPER_CONSOLE" <<WRAPPER_EOF
#!/usr/bin/env bash
# Generated by install-vscodium.sh (build ${BUILD}) - edits are overwritten on
# the next run. Starts the ${CONTAINER_NAME} container if needed, then drops
# into a login shell inside it - no VSCodium.
set -euo pipefail
podman start ${CONTAINER_NAME} >/dev/null
exec podman exec --interactive --tty${env_args} ${CONTAINER_NAME} /bin/bash -l
WRAPPER_EOF
  chmod 0755 "$WRAPPER_CONSOLE"

  cat > "$DESKTOP_FILE_CONSOLE" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=vscodium-box Console
GenericName=Terminal
Comment=Raw shell inside the ${CONTAINER_NAME} container, no VSCodium
Exec=${WRAPPER_CONSOLE}
Icon=utilities-terminal
Terminal=true
Categories=Utility;TerminalEmulator;Development;
StartupNotify=false
Keywords=vscodium-box;terminal;shell;console;bash;
DESKTOP_EOF
  chmod 0644 "$DESKTOP_FILE_CONSOLE"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_FILE_CONSOLE")" >/dev/null 2>&1 || true
  fi
}

# A third launcher/desktop pair that restarts the container. Restarting
# re-triggers podman's ',z' SELinux relabel of the bind mounts, because that
# relabel runs at mount time, not at file-in-place time: a file created on the
# host *after* the container was started keeps its host label, and the
# container process (container_t) is then denied reading it until the container
# is restarted. That is the failure mode behind "I dropped a file into the
# repos dir and the box says Permission denied" - the file is there, but its
# SELinux label says it is not for the container. The container runs `sleep
# infinity`, so a restart is quick and only re-relabels; it does not reinstall
# anything. VSCodium and any shell session inside are terminated by this, which
# is the point of making it an explicit step in the app grid rather than
# something the editor triggers on its own.
#
# Icon=view-refresh is a standard icon-theme name (not something this script
# installs). Terminal=true tells the desktop environment to run Exec= inside the
# user's own default terminal, so the restart progress and any error are
# visible.
write_restart_launcher() {
  cat > "$WRAPPER_RESTART" <<WRAPPER_EOF
#!/usr/bin/env bash
# Generated by install-vscodium.sh (build ${BUILD}) - edits are overwritten on
# the next run. Restarts the ${CONTAINER_NAME} container to re-run podman's
# ',z' SELinux relabel of its bind mounts, which is what makes host-created
# files readable from inside the box again. Kills the running VSCodium.
set -euo pipefail
podman stop ${CONTAINER_NAME} >/dev/null
podman start ${CONTAINER_NAME} >/dev/null
echo "Restarted ${CONTAINER_NAME}; its bind mounts have been relabeled for SELinux."
WRAPPER_EOF
  chmod 0755 "$WRAPPER_RESTART"

  cat > "$DESKTOP_FILE_RESTART" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=${CONTAINER_NAME} Restart
GenericName=Restart
Comment=Restart the ${CONTAINER_NAME} container so host-created files are visible inside it
Exec=${WRAPPER_RESTART}
Icon=view-refresh
Terminal=true
Categories=Utility;System;Development;
StartupNotify=false
Keywords=vscodium-box;podman;restart;relabel;
DESKTOP_EOF
  chmod 0644 "$DESKTOP_FILE_RESTART"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_FILE_RESTART")" >/dev/null 2>&1 || true
  fi
}

# Returns success when an already-created container was given the NVIDIA GPU
# (i.e. its CDI device nodes carry /dev/nvidia*). Used on update runs, where
# create_container is not called again, so the provisioner still knows to
# (re)install the CUDA LLM runtimes for a box that predates them or was created
# on a GPU host.
container_has_nvidia() {
  podman container exists "$CONTAINER_NAME" \
    && podman inspect "$CONTAINER_NAME" \
      --format '{{range .HostConfig.Devices}}{{.PathOnHost}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -q nvidia
}

do_install() {
  require_podman

  if container_exists; then
    check_legacy_container
    echo "Container '$CONTAINER_NAME' already exists - updating in place."
    if container_has_nvidia; then
      # An existing box that was created on a GPU host (or is being upgraded to
      # this CUDA feature): light the same path as a fresh --cuda create, so the
      # provisioner (re)installs the CUDA LLM runtimes and the SELinux rule is
      # (re)ensured.
      CUDA_ACTIVE=1
    elif [ "$USE_CUDA" -eq 1 ] && nvidia_cuda_available; then
      # The container predates the CUDA feature but this host can hand over the
      # GPU now. Can't change a running container's devices - the user must
      # recreate - but we can say so plainly instead of silently doing nothing.
      echo "Note: this host has a usable NVIDIA GPU, but an existing container's devices are fixed at creation."
      echo "  Run ./uninstall-vscodium.sh and install again (no flags needed) to expose the GPU and provision the CUDA LLM runtimes."
    fi
    if [ -n "$REPOS_DIR" ] || [ "$GPU_FLAG_GIVEN" -eq 1 ] || [ "$X11_FLAG_GIVEN" -eq 1 ] \
       || [ "$CUDA_FLAG_GIVEN" -eq 1 ] || [ ${#PUBLISH_PORTS[@]} -gt 0 ]; then
      echo "Note: --repos-dir, --wayland, --gpu/--no-gpu, --cuda/--no-cuda and --publish only take effect when"
      echo "the container is created. Run ./uninstall-vscodium.sh and install again to change them."
      if [ -n "$REPOS_DIR" ]; then
        REPOS_DIR="$(validate_repos_dir "$REPOS_DIR")" || exit 1
        save_repos_dir "$REPOS_DIR"
      fi
    fi
  else
    resolve_repos_dir
    create_container
  fi

  # CUDA_ACTIVE is now whatever it should be on both paths (from create_container,
  # or from container_has_nvidia on an update). Ensure the one SELinux rule the
  # GPU needs.
  ensure_nvidia_selinux_module

  provision_container
  write_launcher
  write_console_launcher
  write_restart_launcher

  echo
  echo "Done. VSCodium should now appear in your application launcher, alongside a"
  echo "'vscodium-box Console' entry for a raw shell in the container (no editor) and"
  echo "a 'vscodium-box Restart' entry that restarts the container to make files you"
  echo "drop into the mounted folders readable inside it again (SELinux relabel)."
  echo "git, gh, the lint toolchain and DeepSeek Harness are installed inside the container too."
  echo "Run 'dsh web' in VSCodium's terminal and log in on first use."
  if [ "$WITH_CLAUDE" -eq 1 ]; then
    echo "Claude Code is installed too - run 'claude' and log in on first use."
  else
    echo "Claude Code was not installed; re-run with --claude to add it."
  fi
  if [ "$WITH_WM_HARNESSES" -eq 1 ]; then
    echo "MarkLLM and reverse-SynthID backends are installed for the watermarks service."
  else
    echo "MarkLLM / reverse-SynthID backends were skipped (--no-wm-harnesses)."
  fi
  if [ "$CUDA_ACTIVE" -eq 1 ]; then
    echo "NVIDIA GPU is exposed to the container (CDI). Confirm inside the box with: podman exec vscodium-box nvidia-smi"
    if [ "$WITH_LLM" -eq 1 ]; then
      echo "CUDA LLM runtimes (vLLM, Ollama, llama.cpp) and the CUDA toolkit are provisioned inside the box."
    else
      echo "CUDA LLM runtime provisioning was skipped (--no-llm)."
    fi
  elif [ "$USE_CUDA" -eq 1 ]; then
    echo "No NVIDIA GPU was exposed (no /dev/nvidiactl + nvidia.com/gpu CDI spec) - the CUDA LLM runtimes were not installed."
  fi
  echo "Re-run this script any time to update everything."
}

do_install
