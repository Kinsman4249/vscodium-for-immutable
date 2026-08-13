#!/usr/bin/env bash
#
# Provisioning script for the 'vscodium-box' container. This is NOT meant to be
# run by hand on the host - install-vscodium.sh pipes it into the container as
# root:
#
#   podman exec -i --user root vscodium-box bash -s < provision-container.sh
#
# It is piped rather than copied in on purpose: nothing is written to a file
# that a process inside the container could rewrite between the write and the
# exec, and no temp file is left behind in the container's home.
#
# It runs as root inside the container, so there is no 'sudo' anywhere below.
#
# Inputs (passed by install-vscodium.sh via `podman exec --env`):
#   BOX_USER   name of the account to create inside the container
#   BOX_UID    its uid   (matches the host user, see --userns keep-id)
#   BOX_GID    its gid   (same)
#   BOX_HOME   its home directory (the container's private home volume)
#   BOX_DEBUG  1 to trace every command
#
set -euo pipefail

# Bump this whenever this script's logic changes. Shown in --debug output so you
# can tell which version produced a given log.
BUILD="2026.08.13-2"

if [ "${BOX_DEBUG:-0}" = "1" ]; then
  echo "[debug] provision-container.sh build $BUILD"
  set -x
fi

: "${BOX_USER:?BOX_USER not set - run this through install-vscodium.sh}"
: "${BOX_UID:?BOX_UID not set - run this through install-vscodium.sh}"
: "${BOX_GID:?BOX_GID not set - run this through install-vscodium.sh}"
: "${BOX_HOME:?BOX_HOME not set - run this through install-vscodium.sh}"

export DEBIAN_FRONTEND=noninteractive

# --- helpers ----------------------------------------------------------------

# Checks that every PRIMARY key in a keyring/key file is one we expect.
#
# $1 = path to the key file, $2 = space-separated list of allowed fingerprints.
#
# Why "every primary key" rather than "the one we want is in there": a key file
# can carry more than one key (GitHub's carries two), and an attacker who can
# swap the download could otherwise append their own key to a file that still
# contains the legitimate one, and apt would then trust both.
#
# --with-colons is the machine-readable form; the human-readable output spaces
# fingerprints in groups of four and would have to be normalized before it could
# be compared. In that format a 'fpr' record belongs to the record above it, so
# only the 'fpr' that directly follows a 'pub' is a primary key's fingerprint;
# the ones following 'sub' are subkeys and are not pinned here.
key_fingerprints_ok() {
  local keyfile="$1" allowed="$2" fprs fpr
  fprs="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
    | awk -F: '/^pub:/ { want = 1; next } /^fpr:/ { if (want) { print $10; want = 0 } }')"
  [ -n "$fprs" ] || return 1
  for fpr in $fprs; do
    case " $allowed " in
      *" $fpr "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Downloads a signing key, checks its fingerprints, and installs it only if they
# match. Returns non-zero (without installing anything) on any failure, so the
# caller can skip that repository and leave the rest of the install alone.
#
# $1 = URL, $2 = destination path, $3 = allowed fingerprints, $4 = "dearmor" to
# convert an ASCII-armored key to a binary keyring, anything else to keep as-is.
install_signing_key() {
  local url="$1" dest="$2" allowed="$3" mode="${4:-asis}" tmp rc=0
  tmp="$(mktemp)"
  if ! wget -qO "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  if key_fingerprints_ok "$tmp" "$allowed"; then
    if [ "$mode" = "dearmor" ]; then
      gpg --dearmor < "$tmp" > "${tmp}.gpg"
      install -m 0644 "${tmp}.gpg" "$dest"
      rm -f "${tmp}.gpg"
    else
      install -m 0644 "$tmp" "$dest"
    fi
  else
    rc=2
  fi
  rm -f "$tmp"
  return "$rc"
}

# --- base tooling -----------------------------------------------------------

echo "Updating package lists..."
apt-get update -qq

echo "Ensuring base tooling (curl, gnupg, wget, ca-certificates, git, sudo) is present..."
apt-get install -y -qq curl gnupg wget ca-certificates git sudo >/dev/null

# --- container user ---------------------------------------------------------
#
# The debian:12 image has no account for the host user's uid. Without one,
# `getent passwd` fails and git, VSCodium and Claude Code all fall over looking
# for a home directory. The uid/gid deliberately match the host user's, because
# the container runs with `--userns keep-id`, so files written into the mounted
# repos directory keep the right ownership on the host side.
if ! getent group "$BOX_GID" >/dev/null 2>&1; then
  groupadd --gid "$BOX_GID" "$BOX_USER"
fi
if ! getent passwd "$BOX_UID" >/dev/null 2>&1; then
  useradd --uid "$BOX_UID" --gid "$BOX_GID" --home-dir "$BOX_HOME" \
    --shell /bin/bash --no-create-home "$BOX_USER"
fi

# On ostree hosts the home directory really lives at /var/home/<user>, and
# /home is a symlink to /var/home. The container has no such symlink, so a path
# copied from the host ("/home/<user>/...") would not resolve inside it. Add the
# same symlink, but only when /home is empty of a real directory for this user,
# so nothing is ever clobbered.
case "$BOX_HOME" in
  /var/home/*)
    if [ ! -e "/home/${BOX_USER}" ]; then
      mkdir -p /home
      ln -sfn "$BOX_HOME" "/home/${BOX_USER}"
    fi
    ;;
esac

# Passwordless sudo INSIDE the container only. This grants nothing on the host:
# the container is rootless, so container root is just the unprivileged host
# user seen through a user namespace.
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$BOX_USER" > /etc/sudoers.d/vscodium-box
chmod 0440 /etc/sudoers.d/vscodium-box

# XDG_RUNTIME_DIR: podman auto-creates this directory as the parent of the
# Wayland socket bind mount, owned by root and world-readable. Applications
# expect it to be owned by the user and mode 0700, and some refuse to start
# otherwise.
if [ -d "/run/user/$BOX_UID" ]; then
  chown "$BOX_UID:$BOX_GID" "/run/user/$BOX_UID"
  chmod 0700 "/run/user/$BOX_UID"
fi

# --- VSCodium apt repository -----------------------------------------------
# Official method from https://vscodium.com/ : pull the signing key, dearmor it
# into a dedicated keyring, and pin the repo to that keyring with signed-by.
#
# The fingerprint below is ALSO checked, but be clear about what that buys:
# VSCodium publishes no fingerprint anywhere, and the key is fetched from the
# same gitlab URL the repo instructions point at, so this pin is change
# detection, not an independent trust anchor. It catches a later key rotation or
# a tampered response - it cannot tell you the key was ever the right one. It
# was read off the published key with `gpg --show-keys --with-colons`.
VSCODIUM_KEYRING="/usr/share/keyrings/vscodium-archive-keyring.gpg"
VSCODIUM_FINGERPRINTS="1302DE60231889FE1EBACADC54678CF75A278D9C"
if [ ! -f "$VSCODIUM_KEYRING" ]; then
  echo "Installing the VSCodium signing key..."
  if install_signing_key \
      https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
      "$VSCODIUM_KEYRING" "$VSCODIUM_FINGERPRINTS" dearmor; then
    :
  else
    echo "WARNING: could not install a trusted VSCodium signing key (download failed, or the key did not match the expected fingerprint) - skipping VSCodium."
  fi
fi
# Only register the repo if the key passed the gate above; a repo whose
# signed-by keyring is missing makes every later `apt-get update` fail.
if [ -f "$VSCODIUM_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/vscodium.list ]; then
  echo "Registering the VSCodium apt repository..."
  echo "deb [arch=amd64,arm64 signed-by=${VSCODIUM_KEYRING}] https://download.vscodium.com/debs vscodium main" \
    > /etc/apt/sources.list.d/vscodium.list
fi

# --- GitHub CLI (gh) apt repository ----------------------------------------
# Debian 12 doesn't carry gh in its own repos, so install it from GitHub's apt
# repo (official method from
# https://github.com/cli/cli/blob/trunk/docs/install_linux.md).
#
# Unlike VSCodium, GitHub does publish the fingerprints, at the top of that same
# document, so this pin is a real second channel. Both keys are listed there;
# the keyring file currently carries both, and the older one expires in early
# 2027, so the file will be rotated - which is exactly why this pins the
# fingerprints and not the SHA-256 of the file that document also publishes.
GH_KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
GH_FINGERPRINTS="2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325"
# -m on mkdir -p only applies to the deepest directory, so set the mode
# explicitly - apt requires this directory to be readable by _apt.
mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings
if [ ! -f "$GH_KEYRING" ]; then
  echo "Installing the GitHub CLI signing key..."
  if install_signing_key \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      "$GH_KEYRING" "$GH_FINGERPRINTS"; then
    chmod go+r "$GH_KEYRING"
  else
    echo "WARNING: could not install a trusted GitHub CLI signing key (download failed, or the key did not match the expected fingerprints) - skipping gh."
  fi
fi
if [ -f "$GH_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/github-cli.list ]; then
  echo "Registering the GitHub CLI apt repository..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=${GH_KEYRING}] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
fi

# --- Claude Code apt repository --------------------------------------------
# Anthropic publishes signed apt/dnf/apk repositories, so Claude Code is
# installed the same signed-by way as the two repos above rather than through
# the `curl https://claude.ai/install.sh | bash` one-liner the docs lead with.
# A package manager install is the better fit here: it survives container
# rebuilds through this script, and it keeps the binary out of ~/.local/bin.
# Method and key fingerprint: https://code.claude.com/docs/en/setup
#
# The 'stable' channel is roughly a week behind 'latest' and skips releases with
# major regressions. To follow 'latest' instead, both the URL path and the suite
# name change: .../apt/latest latest main
CLAUDE_KEYRING="/etc/apt/keyrings/claude-code.asc"
CLAUDE_FINGERPRINTS="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
if [ ! -f "$CLAUDE_KEYRING" ]; then
  echo "Installing the Claude Code signing key..."
  if install_signing_key \
      https://downloads.claude.ai/keys/claude-code.asc \
      "$CLAUDE_KEYRING" "$CLAUDE_FINGERPRINTS"; then
    :
  else
    echo "WARNING: could not install a trusted Claude Code signing key (download failed, or the key did not match the expected fingerprint) - skipping Claude Code."
  fi
fi
if [ -f "$CLAUDE_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/claude-code.list ]; then
  echo "Registering the Claude Code apt repository..."
  echo "deb [signed-by=${CLAUDE_KEYRING}] https://downloads.claude.ai/claude-code/apt/stable stable main" \
    > /etc/apt/sources.list.d/claude-code.list
fi

# --- packages ---------------------------------------------------------------

echo "Installing/updating the lint toolchain..."
apt-get update -qq
apt-get install -y shellcheck jq fd-find yamllint

# VSCodium and gh each get their own install call, so that one repository having
# a bad day cannot take the others down with it.
if [ -f /etc/apt/sources.list.d/vscodium.list ]; then
  echo "Installing/updating VSCodium..."
  apt-get install -y codium \
    || echo "WARNING: could not install VSCodium. Everything else is unaffected."
fi

if [ -f /etc/apt/sources.list.d/github-cli.list ]; then
  echo "Installing/updating the GitHub CLI..."
  apt-get install -y gh \
    || echo "WARNING: could not install gh. Everything else is unaffected."
fi

# apt installs of Claude Code do not self-update; re-running the installer
# upgrades it along with everything else.
if [ -f /etc/apt/sources.list.d/claude-code.list ]; then
  echo "Installing/updating Claude Code..."
  apt-get install -y claude-code \
    || echo "WARNING: could not install Claude Code. Everything else is unaffected."
fi

# --- Chromium ----------------------------------------------------------------
# Debian 12 carries chromium in its own main repo, so this needs no separate
# signing key or apt source - unlike VSCodium/gh/Claude Code above.
#
# Reason it's here: sites that gate login behind a WebAuthn/passkey prompt run
# that flow entirely in the browser's own JS, so having a real browser inside
# the container is enough to click through them. This does NOT wire up a
# physical security key (YubiKey/FIDO2 USB) - that would need /dev/hidraw or
# /dev/bus/usb passed into the container, which install-vscodium.sh does not
# do.
echo "Installing/updating Chromium..."
apt-get install -y chromium \
  || echo "WARNING: could not install Chromium. Everything else is unaffected."

# Debian ships fd as 'fdfind' because the name 'fd' was already taken by another
# package. Nearly every fd example online says 'fd', so add the conventional
# alias in /usr/local/bin, which is part of the container's own filesystem and
# never visible to the host. Never clobber a real 'fd' binary.
if command -v fdfind >/dev/null 2>&1; then
  FD_SHIM="/usr/local/bin/fd"
  if [ -L "$FD_SHIM" ] || [ ! -e "$FD_SHIM" ]; then
    ln -sf "$(command -v fdfind)" "$FD_SHIM"
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
      install -m 0755 "${ACTIONLINT_TMP}/actionlint" /usr/local/bin/actionlint
      echo "actionlint ${ACTIONLINT_VERSION} installed."
    else
      echo "WARNING: actionlint checksum mismatch - refusing to install it. Everything else is unaffected."
    fi
  else
    echo "WARNING: could not download actionlint - skipping it. Everything else is unaffected."
  fi
  rm -rf "$ACTIONLINT_TMP"
fi

# --- runpodctl ---------------------------------------------------------------
# Debian 12 has no runpodctl package, so install the upstream release binary,
# same approach as actionlint above: pin the version and per-arch SHA-256, no
# signing key available for this one.
#
# TO BUMP: pick the new version, then get its checksums from
#   https://github.com/runpod/runpodctl/releases/download/vX.Y.Z/checksums_X.Y.Z_sha256.txt
RUNPODCTL_VERSION="2.9.0"
RUNPODCTL_SHA256_amd64="06e6f54957db79d5cd9f1909a7f1d365076826751ba2f5df65d75dde43a64148"
RUNPODCTL_SHA256_arm64="b8afac8d983f255f566fba718e766a6959957ef7d8f2bae9dd965aadbadc92bd"

RUNPODCTL_ARCH="$(dpkg --print-architecture)"
case "$RUNPODCTL_ARCH" in
  amd64) RUNPODCTL_SHA256="$RUNPODCTL_SHA256_amd64" ;;
  arm64) RUNPODCTL_SHA256="$RUNPODCTL_SHA256_arm64" ;;
  *)     RUNPODCTL_SHA256="" ;;
esac

if [ -z "$RUNPODCTL_SHA256" ]; then
  echo "Note: no pinned runpodctl checksum for architecture '${RUNPODCTL_ARCH}' - skipping runpodctl."
elif [ "$(runpodctl --version 2>/dev/null | awk '{print $NF}')" = "$RUNPODCTL_VERSION" ]; then
  echo "runpodctl ${RUNPODCTL_VERSION} already installed."
else
  echo "Installing runpodctl ${RUNPODCTL_VERSION}..."
  RUNPODCTL_TMP="$(mktemp -d)"
  RUNPODCTL_BIN="runpodctl-linux-${RUNPODCTL_ARCH}"
  if wget -qO "${RUNPODCTL_TMP}/${RUNPODCTL_BIN}" \
      "https://github.com/runpod/runpodctl/releases/download/v${RUNPODCTL_VERSION}/${RUNPODCTL_BIN}"; then
    # Verify BEFORE installing, and bail out without installing on a mismatch.
    if printf '%s  %s\n' "$RUNPODCTL_SHA256" "${RUNPODCTL_TMP}/${RUNPODCTL_BIN}" \
        | sha256sum --check --status; then
      install -m 0755 "${RUNPODCTL_TMP}/${RUNPODCTL_BIN}" /usr/local/bin/runpodctl
      echo "runpodctl ${RUNPODCTL_VERSION} installed."
    else
      echo "WARNING: runpodctl checksum mismatch - refusing to install it. Everything else is unaffected."
    fi
  else
    echo "WARNING: could not download runpodctl - skipping it. Everything else is unaffected."
  fi
  rm -rf "$RUNPODCTL_TMP"
fi

echo "Container provisioning complete."
