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
BUILD="2026.08.16-1"

if [ "${BOX_DEBUG:-0}" = "1" ]; then
  echo "[debug] provision-container.sh build $BUILD"
  set -x
fi

: "${BOX_USER:?BOX_USER not set - run this through install-vscodium.sh}"
: "${BOX_UID:?BOX_UID not set - run this through install-vscodium.sh}"
: "${BOX_GID:?BOX_GID not set - run this through install-vscodium.sh}"
: "${BOX_HOME:?BOX_HOME not set - run this through install-vscodium.sh}"
# 1 when the host handed the NVIDIA GPU to the container via --device
# nvidia.com/gpu=all (CDI). Off when there was no GPU/CDI setup to pass.
: "${BOX_WITH_CUDA:-0}"
# 1 to provision the CUDA LLM runtimes (vLLM/Ollama/llama.cpp) and the CUDA
# toolkit inside the box. On when the host had a GPU and didn't pass --no-llm.
: "${BOX_WITH_LLM:-0}"

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

echo "Ensuring base tooling (curl, gnupg, wget, ca-certificates, git, sudo, python3) is present..."
# python3 + python3-venv: the MarkLLM / reverse-SynthID backends make their own
# .venv with `python3 -m venv`, which on Debian 12 needs python3-venv; python3
# was never explicitly installed since the watermarks service itself is
# stdlib-only.
apt-get install -y -qq curl gnupg wget ca-certificates git sudo python3 python3-venv >/dev/null

# --- locale -------------------------------------------------------------------
# Debian's minimal image leaves LANG/LC_ALL unset, which falls back to the
# POSIX/C locale. That breaks tools that assume a Unicode-aware locale - e.g.
# `grep -P '[\x{1F300}-\x{1FAFF}]'` (matching emoji by codepoint, as the
# release-gh skill's ASCII lint does) errors out under it instead of just
# finding no matches. glibc has shipped the C.UTF-8 locale built in since
# 2.35, so no `locales` package or `locale-gen` is needed - just point at it.
#
# This has to be a shell default rather than a container-level `podman create
# --env`, because VSCodium's integrated terminal (and anything launched from
# it, including Claude Code) is what needs the fix, and that terminal is an
# interactive, non-login bash shell. Debian's bash package always sources
# /etc/bash.bashrc for those, regardless of whether the user has their own
# ~/.bashrc, so appending here reaches every shell without needing the
# container to be recreated.
if ! grep -q '^export LANG=C.UTF-8$' /etc/bash.bashrc 2>/dev/null; then
  echo "Setting the default locale to C.UTF-8..."
  {
    echo ''
    echo '# vscodium-box: default to a UTF-8 locale (see provision-container.sh)'
    echo 'export LANG=C.UTF-8'
    echo 'export LC_ALL=C.UTF-8'
  } >> /etc/bash.bashrc
fi

# --- opencode -----------------------------------------------------------------
# opencode installs itself to ~/.opencode/bin but doesn't put itself on PATH.
# Same reasoning as the locale block above: append to /etc/bash.bashrc so every
# interactive shell (including VSCodium's integrated terminal) picks it up
# without needing the container recreated.
if ! grep -q '^export PATH=.*\.opencode/bin' /etc/bash.bashrc 2>/dev/null; then
  echo "Adding opencode to PATH..."
  {
    echo ''
    echo '# vscodium-box: put opencode on PATH (see provision-container.sh)'
    echo "export PATH=${BOX_HOME}/.opencode/bin:\$PATH"
  } >> /etc/bash.bashrc
fi

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
if getent passwd "$BOX_UID" >/dev/null 2>&1; then
  # Rootless podman's --userns=keep-id auto-injects a passwd entry for this
  # uid before we ever get here, built from the host account but with shell
  # forced to /bin/sh and no real home - so the entry always exists and this
  # branch always runs. Fix it up with usermod instead of useradd.
  existing_name="$(getent passwd "$BOX_UID" | cut -d: -f1)"
  if [ "$existing_name" != "$BOX_USER" ]; then
    usermod --login "$BOX_USER" "$existing_name"
    existing_name="$BOX_USER"
  fi
  usermod --home "$BOX_HOME" --shell /bin/bash "$existing_name"
else
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

# --- Claude Code apt repository (optional, BOX_WITH_CLAUDE=1) ---------------
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
#
# Off by default - DeepSeek Harness (below) is the default agent harness now.
# Pass --claude to install-vscodium.sh to opt back into Claude Code.
if [ "${BOX_WITH_CLAUDE:-0}" = "1" ]; then
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
fi

# --- Node.js apt repository (NodeSource) -------------------------------------
# DeepSeek Harness (below) needs Node.js >=24.0.0: its dsh-app-boot dependency
# imports util.parseEnv, added to Node.js in v24.0.0
# (https://nodejs.org/api/util.html#utilparseenvcontent), and dsh's own
# package.json declares "engines": {"node": "^22.19.0 || >=24.0.0"} - so 24.x
# is the version actually required either way. Debian 12's own main repo only
# carries Node.js 18.19, three majors short - confirmed live, that mismatch is
# exactly what crashed every `dsh` invocation with "The requested module
# 'node:util' does not provide an export named 'parseEnv'". So, unlike
# Chromium below (Debian's own package is fine there), Node.js needs its own
# signed apt repo the same way VSCodium/gh/Claude Code above do.
#
# Official method: https://github.com/nodesource/distributions/wiki/Repository-Manual-Installation
# NodeSource does not publish this key's fingerprint anywhere the way GitHub
# and Anthropic do above, so - like VSCodium's key above - this pin is change
# detection, not an independent trust anchor.
NODESOURCE_KEYRING="/etc/apt/keyrings/nodesource.gpg"
NODESOURCE_FINGERPRINTS="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
NODE_MAJOR=24
if [ ! -f "$NODESOURCE_KEYRING" ]; then
  echo "Installing the NodeSource signing key..."
  if install_signing_key \
      https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      "$NODESOURCE_KEYRING" "$NODESOURCE_FINGERPRINTS" dearmor; then
    :
  else
    echo "WARNING: could not install a trusted NodeSource signing key (download failed, or the key did not match the expected fingerprint) - skipping Node.js and DeepSeek Harness."
  fi
fi
if [ -f "$NODESOURCE_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
  echo "Registering the NodeSource apt repository (Node.js ${NODE_MAJOR}.x)..."
  echo "deb [signed-by=${NODESOURCE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
fi

# --- NVIDIA CUDA apt repository (CUDA LLM runtimes) ---------------------------
# Needed to BUILD llama.cpp with CUDA (nvcc + cuBLAS) and to give the box a
# real CUDA toolkit alongside the driver that the host's CDI hook injects. The
# three runtimes differ in what they need the toolkit for:
#
#   - vLLM and Ollama ship their own CUDA runtime in their wheels/binary and
#     only need the *driver* (libcuda, NVML) that the CDI hook mounts - no
#     toolkit. Checked with `python -c 'import torch; torch.cuda.is_available()'`.
#   - llama.cpp ships NO CUDA-enabled Linux prebuilt binary (upstream only
#     publishes CUDA builds for Windows), so it must be compiled here with
#     `-DGGML_CUDA=ON`, which needs nvcc + cuBLAS: the toolkit.
#
# NVIDIA publishes a flat Debian 12 repo and a keyring .deb at the repo root.
# Rather than `dpkg -i` that deb (which also drops its own sources list on
# disk), the keyring is extracted from the .deb and installed with the same
# signed-by + fingerprint gate every other repo here uses, so one mechanism
# verifies everything. The .deb is verified by the explicit SHA-256 below
# BEFORE it is extracted.
#
# TO BUMP: pick the newer cuda-keyring*.deb from
#   https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/
# compute its sha256sum, and update the fingerprints from the key it contains.
CUDA_KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
CUDA_KEYRING_DEB_SHA256="e7f219eab6fe4819cdb5c15b98233dc3420302d9c00883219cd3d896857cf48d"
CUDA_KEYRING="/usr/share/keyrings/cuda-archive-keyring.gpg"
CUDA_FINGERPRINTS="EB693B3035CD5710E231E123A4B469963BF863CC"
if [ ! -f "$CUDA_KEYRING" ]; then
  echo "Installing the NVIDIA CUDA signing key..."
  CUDA_TMP="$(mktemp -d)"
  if wget -qO "${CUDA_TMP}/${CUDA_KEYRING_DEB}" \
      "https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/${CUDA_KEYRING_DEB}"; then
    if printf '%s  %s\n' "$CUDA_KEYRING_DEB_SHA256" "${CUDA_TMP}/${CUDA_KEYRING_DEB}" \
        | sha256sum --check --status; then
      # Extract just the keyring out of the .deb (dpkg-deb ships with dpkg,
      # which is always present) and gate it on the fingerprints like the
      # install_signing_key helper does for the plain key files.
      CUDA_KEY_TMP="$(mktemp)"
      if dpkg-deb --fsys-tarfile "${CUDA_TMP}/${CUDA_KEYRING_DEB}" \
          | tar -xOf - './usr/share/keyrings/cuda-archive-keyring.gpg' > "$CUDA_KEY_TMP" 2>/dev/null; then
        if key_fingerprints_ok "$CUDA_KEY_TMP" "$CUDA_FINGERPRINTS"; then
          install -m 0644 "$CUDA_KEY_TMP" "$CUDA_KEYRING"
        else
          echo "WARNING: NVIDIA CUDA keyring fingerprints did not match - skipping the CUDA repository and LLM runtimes."
        fi
      else
        echo "WARNING: could not extract the NVIDIA CUDA keyring from ${CUDA_KEYRING_DEB} - skipping the CUDA repository and LLM runtimes."
      fi
      rm -f "$CUDA_KEY_TMP"
    else
      echo "WARNING: NVIDIA CUDA keyring .deb checksum mismatch - refusing to use it. LLM runtimes will be skipped."
    fi
  else
    echo "WARNING: could not download the NVIDIA CUDA keyring .deb - skipping the CUDA LLM runtimes."
  fi
  rm -rf "$CUDA_TMP"
fi
if [ -f "$CUDA_KEYRING" ] && [ ! -f /etc/apt/sources.list.d/cuda.list ]; then
  echo "Registering the NVIDIA CUDA apt repository (debian12/x86_64)..."
  echo "deb [signed-by=${CUDA_KEYRING}] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" \
    > /etc/apt/sources.list.d/cuda.list
fi

# --- packages ---------------------------------------------------------------

echo "Installing/updating the lint toolchain..."
apt-get update -qq
apt-get install -y shellcheck jq fd-find yamllint

# exiftool and qpdf improve the PDF/container metadata strip that the
# watermarks-remover service performs for the remove-ai-marks skill. Both are
# plain Debian 12 main packages. Without them the service degrades on PDFs
# (best-effort XMP strip instead of a real one) but does not break.
echo "Installing/updating exiftool and qpdf..."
apt-get install -y libimage-exiftool-perl qpdf \
  || echo "WARNING: could not install exiftool/qpdf. The watermarks-remover service will degrade on PDF/container strips."

# CPU-only cheap image analysis for the `visualize` skill: tesseract (OCR),
# ImageMagick (identify/convert + histogram color), and python3-PIL/numpy for
# the color/detail heuristics. python3-opencv is optional (faces via Haar
# cascade). All are plain Debian 12 main packages. Without them the skill
# still reports identity via exiftool and honestly marks the rest unavailable.
echo "Installing/updating the visualize skill's CPU image-analysis tools..."
apt-get install -y tesseract-ocr imagemagick python3-pil python3-numpy python3-opencv file \
  || echo "WARNING: could not install tesseract/imagemagick/python3-PIL/numpy/opencv/file. The visualize skill will degrade to exiftool identity only."

# libsecret-tools: provides the `secret-tool` binary that runpod-helper's
# startup.sh uses to store RUNPOD_API_KEY in the OS keyring instead of a
# plaintext file. Needs a reachable D-Bus session bus with an unlocked Secret
# Service (GNOME Keyring/KWallet) to actually work - not something apt can
# provide - so this only satisfies the package prerequisite; see
# runpod-helper/PREREQUISITES.md for the D-Bus caveat.
echo "Installing/updating libsecret-tools..."
apt-get install -y libsecret-tools \
  || echo "WARNING: could not install libsecret-tools. runpod-helper's secret-tool step will be skipped."

# Node.js: prereq for DeepSeek Harness (below). Installed from the NodeSource
# repo registered above - see that section for why Debian's own package is
# too old. npm ships bundled with NodeSource's nodejs package, so there is no
# separate npm package to install here (unlike the old Debian-package setup).
echo "Installing/updating Node.js..."
if [ -f /etc/apt/sources.list.d/nodesource.list ]; then
  apt-get install -y nodejs \
    || echo "WARNING: could not install Node.js. DeepSeek Harness will be skipped."
else
  echo "Note: the NodeSource apt repository isn't registered - skipping Node.js and DeepSeek Harness."
fi

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

# --- DeepSeek Harness (default agent harness) --------------------------------
# DeepSeek's open-source (MIT) agent harness, "dsh". Node-based, so it installs
# from npm rather than apt - there is no apt/dnf/apk repo for it the way there
# is for Claude Code above. https://github.com/deepseek-ai/deepseek-harness
#
# Still a developer preview (first released 2026-08-13): compatibility-breaking
# changes are expected, and npm's own registry integrity checks are the only
# verification available - there is no published signing key to pin the way the
# apt repos above are pinned.
if command -v npm >/dev/null 2>&1; then
  echo "Installing/updating DeepSeek Harness..."
  # Two npm quirks, both confirmed live, that a plain `npm install -g` silently
  # falls over on:
  #
  # 1. npm 11.16+ (shipped in the Node 24.x installed above) gates every
  #    dependency's install-time lifecycle scripts behind an explicit
  #    allowlist by default - part of npm v12's supply-chain hardening
  #    (https://github.blog/changelog/2026-06-09-upcoming-breaking-changes-for-npm-v12/).
  #    Unlisted packages have their scripts *skipped with a warning*, not
  #    failed outright, so the install reports success while node-pty's
  #    postinstall (which compiles its native pty.node binding) never runs -
  #    every `dsh` invocation then crashes at plugin-boot with "Cannot find
  #    module './prebuilds/linux-x64//pty.node'". The five names below are
  #    exactly what npm itself names as pending when you hit this ("N
  #    packages have install scripts not yet covered by allowScripts"), sized
  #    to this DeepSeek Harness release - if a future dsh version adds a new
  #    native dependency, expect the same failure mode until it's added here
  #    too.
  # 2. Separately, sharp's own platform-specific optional dependency
  #    (@img/sharp-linux-x64) doesn't reliably get pulled by a global
  #    install - a long-standing npm bug resolving nested optionalDependencies
  #    under `-g`. --include=optional is sharp's own documented workaround
  #    (https://sharp.pixelplumbing.com/install#cross-platform).
  npm install -g --include=optional \
    --allow-scripts=koffi,node-pty,protobufjs,@deepseek-ai/dsh-subprocess-local,@google/genai \
    @deepseek-ai/dsh \
    || echo "WARNING: could not install DeepSeek Harness. Everything else is unaffected."
  # The global package itself lands under /usr/local/lib/node_modules
  # (root-owned by design), but npm's cache always lives under $HOME, and
  # $HOME here is BOX_HOME - the container's env default (see HOME= in
  # install-vscodium.sh's `podman create`), not root's own /root. Since this
  # whole script runs as root, that means every npm invocation above just
  # wrote cache/log files into the box user's home as root - confirmed live,
  # 6000+ root-owned files under ~/.npm - which then EACCESs the very next
  # `npm install` the box user runs themselves. Fix ownership unconditionally;
  # cheap, and a no-op once it's already right.
  if [ -d "${BOX_HOME}/.npm" ]; then
    chown -R "${BOX_UID}:${BOX_GID}" "${BOX_HOME}/.npm"
  fi
else
  echo "Note: npm is not available - skipping DeepSeek Harness."
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

# --- watermarks-remover service ---------------------------------------------
# The remove-ai-marks skill cleans through this HTTP service. It runs INSIDE
# this container on purpose: the box has a private network namespace, so a
# host-side service on 127.0.0.1 is not reachable from it (which is why this
# session started on demand via the wrapper below). The engine is python
# stdlib only, so no venv or pip is needed - just the scripts.
#
# Debian 12 has no watermarks-remover package, so vendor the upstream source
# tarball, same approach as actionlint/runpodctl above: pin the version and an
# explicit SHA-256, verify BEFORE extracting. The tarball is a SOURCE archive,
# so a single checksum covers every architecture - no per-arch split like those
# two.
#
# TO BUMP: pick a new upstream release tag, download
#   https://github.com/guillaumemeyer/watermarks-remover/archive/refs/tags/vX.Y.Z.tar.gz
# and compute its sha256sum.
WM_VERSION="0.5.0"
WM_SHA256="4dbb6b26bc659ad4803225d2b072d1cbb1f318ce9ea421f42d78bbec0eccc73a"
WM_LIB="/usr/local/lib/watermarks-remover"
WM_TAR="watermarks-remover-v${WM_VERSION}.tar.gz"

# Re-runs of this script are meant to be cheap: skip the download when the
# pinned version is already installed.
if [ -f "${WM_LIB}/version" ] && [ "$(cat "${WM_LIB}/version")" = "$WM_VERSION" ]; then
  echo "watermarks-remover service ${WM_VERSION} already installed."
else
  echo "Installing the watermarks-remover service ${WM_VERSION}..."
  WM_TMP="$(mktemp -d)"
  if wget -qO "${WM_TMP}/${WM_TAR}" \
      "https://github.com/guillaumemeyer/watermarks-remover/archive/refs/tags/v${WM_VERSION}.tar.gz"; then
    # Verify BEFORE extracting, and bail out without installing on a mismatch.
    if printf '%s  %s\n' "$WM_SHA256" "${WM_TMP}/${WM_TAR}" \
        | sha256sum --check --status; then
      tar xzf "${WM_TMP}/${WM_TAR}" -C "$WM_TMP" --wildcards "*/service/scripts/*"
      rm -rf "$WM_LIB"
      mkdir -p "$WM_LIB"
      # The top directory in the tarball is watermarks-remover-<version>.
      cp "${WM_TMP}"/watermarks-remover-*/service/scripts/* "$WM_LIB"/
      printf '%s\n' "$WM_VERSION" > "$WM_LIB/version"
      # The wrapper runs as the box user, not root, so this must be readable
      # and traversable by everyone.
      chmod -R a+rX "$WM_LIB"
      echo "watermarks-remover service ${WM_VERSION} installed."
    else
      echo "WARNING: watermarks-remover checksum mismatch - refusing to install it. Everything else is unaffected."
    fi
  else
    echo "WARNING: could not download watermarks-remover - skipping it. Everything else is unaffected."
  fi
  rm -rf "$WM_TMP"
fi

# --- standalone CPython 3.12 (watermark-harness interpreter) ------------------
# The vendored MarkLLM / reverse-SynthID requirement files are written for
# Python >=3.12 - they pin numpy==2.5.2 and scipy==1.18.0, both of which require
# Python 3.12 - but Debian 12 ships only python3.11, while touching the vendored
# pins would deviate from upstream's validated set. Instead, provide a
# self-contained CPython 3.12 (astral's python-build-standalone, a glibc build
# that runs on bookworm) and build the harness venvs on it. Pinned the same way
# as actionlint/runpodctl/watermarks-remover above: an explicit SHA-256 is
# verified BEFORE extracting.
#
# TO BUMP: pick a newer release tag from
#   https://github.com/astral-sh/python-build-standalone/releases
# and download the cpython-3.12.*+<tag>-x86_64-unknown-linux-gnu-install_only.tar.gz
# for it, then compute its sha256sum.
PY312_TAG="20260814"
PY312_VERSION="3.12.14"
PY312_SHA256="3297691ae34f75fed81ac424e040145fccb0bafe8e581cd5cadbddfa1c0766c0"
PY312_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY312_TAG}/cpython-${PY312_VERSION}%2B${PY312_TAG}-x86_64-unknown-linux-gnu-install_only.tar.gz"
PY312_TAR="cpython-${PY312_VERSION}+${PY312_TAG}-x86_64-unknown-linux-gnu-install_only.tar.gz"
PY312_DIR="/usr/local/lib/python-build-standalone"
PY312_BIN="${PY312_DIR}/python/bin/python3.12"

# Re-runs are cheap: skip the download when the built interpreter is already in
# place. Guarded by BOX_WITH_WM_HARNESSES too, so --no-wm-harnesses never fetches
# a runtime it does not need.
if [ "${BOX_WITH_WM_HARNESSES:-1}" = "1" ] && [ ! -x "$PY312_BIN" ]; then
  echo "Installing standalone CPython ${PY312_VERSION} for the watermark harnesses..."
  PY312_TMP="$(mktemp -d)"
  if wget -qO "${PY312_TMP}/${PY312_TAR}" "$PY312_URL"; then
    if printf '%s  %s\n' "$PY312_SHA256" "${PY312_TMP}/${PY312_TAR}" \
        | sha256sum --check --status; then
      mkdir -p "$PY312_DIR"
      tar xzf "${PY312_TMP}/${PY312_TAR}" -C "$PY312_DIR"
      # The harness runs as the box user, not root, so this must be readable
      # and traversable by everyone.
      chmod -R a+rX "$PY312_DIR"
      echo "Standalone CPython ${PY312_VERSION} installed."
    else
      echo "WARNING: CPython ${PY312_VERSION} checksum mismatch - refusing to install it. The watermark harnesses will be unavailable."
    fi
  else
    echo "WARNING: could not download CPython ${PY312_VERSION} - skipping it. The watermark harnesses will be unavailable."
  fi
  rm -rf "$PY312_TMP"
fi

# --- watermark harness backends (MarkLLM / reverse-SynthID) -------------------
# These give the watermarks-remover service same-scheme verification for the
# rewrite-ai-marks skill. On by default, opt-out with --no-wm-harnesses.
# The setup scripts clone upstream (THU-BPM/MarkLLM, aloshdenny/reverse-SynthID)
# into $HOME and make their own .venv on the standalone 3.12 above (torch
# install is the slow, first-run part). Each step is non-fatal: a failure prints
# a WARNING and provisioning continues, so the wrapper below is still written
# either way.
if [ "${BOX_WITH_WM_HARNESSES:-1}" = "1" ] && [ -x "$PY312_BIN" ]; then
  # A venv left over from before this standalone-Python step is a python3.11
  # venv and unusable (the vendored requirements cannot resolve on 3.11). Drop
  # any venv whose interpreter is not 3.12 so setup recreates it on the right
  # one; the git checkouts themselves are kept, so there is no re-clone.
  for dir in "$HOME/MarkLLM" "$HOME/reverse-SynthID"; do
    if [ -x "$dir/.venv/bin/python" ] \
       && ! "$dir/.venv/bin/python" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 12) else 1)' 2>/dev/null; then
      rm -rf "$dir/.venv"
    fi
  done
  if [ -f "${WM_LIB}/setup_markllm.sh" ]; then
    echo "Installing the MarkLLM watermark harness (torch download on first run)..."
    MARKLLM_DIR="$HOME/MarkLLM" bash "${WM_LIB}/setup_markllm.sh" --python "$PY312_BIN" \
      || echo "WARNING: could not set up MarkLLM - the watermarks service will report harnesses.markllm as false."
    # Upstream v0.5.0's setup_markllm.sh sparse-checkout omits /visualize/, which
    # every MarkLLM algorithm imports at top level (KGW generation fails with
    # "No module named 'visualize'" without it). R2 confirmed this live. Add the
    # missing module to the checkout; idempotent on re-runs, non-fatal.
    if [ -d "$HOME/MarkLLM/.git" ]; then
      git -C "$HOME/MarkLLM" sparse-checkout add '/visualize/' \
        || echo "WARNING: could not add MarkLLM /visualize/ to the sparse checkout - the MarkLLM harness may fail to generate/detect."
    fi
  else
    echo "WARNING: setup_markllm.sh is not vendored - skipping the MarkLLM harness."
  fi
  if [ -f "${WM_LIB}/setup_synthid.sh" ]; then
    echo "Installing the reverse-SynthID watermark harness..."
    REVERSE_SYNTHID_DIR="$HOME/reverse-SynthID" bash "${WM_LIB}/setup_synthid.sh" --python "$PY312_BIN" \
      || echo "WARNING: could not set up reverse-SynthID - the watermarks service will report scorers.synthid as false."
  else
    echo "WARNING: setup_synthid.sh is not vendored - skipping the reverse-SynthID harness."
  fi
  # The setup scripts run as root but $HOME resolves to the box user's private
  # home, so every file they wrote is root-owned and the box user gets EACCES
  # on the .venv. Fix ownership unconditionally; cheap, and a no-op once it's
  # already right (same fix the DeepSeek Harness npm section applies).
  if [ -n "${BOX_USER:-}" ]; then
    chown -R "${BOX_USER}:${BOX_GID}" "$HOME/MarkLLM" "$HOME/reverse-SynthID" 2>/dev/null
  fi
elif [ "${BOX_WITH_WM_HARNESSES:-1}" = "1" ]; then
  echo "WARNING: the standalone CPython for the watermark harnesses is unavailable - harnesses.markllm and scorers.synthid will report false."
fi

# --- CUDA toolkit + LLM runtimes (vLLM / Ollama / llama.cpp) ------------------
# Only when the host handed the GPU over (BOX_WITH_CUDA=1, i.e. --device
# nvidia.com/gpu=all) and the LLM runtimes were asked for (BOX_WITH_LLM=1). The
# NVIDIA CDI hook already mounts the driver (libcuda, NVML, nvidia-smi) into the
# box, so nothing here installs a driver - this is the CUDA *toolkit* and the
# three runtimes on top of it. Intentionally gated hard: on a host with no GPU
# this is many gigabytes of mostly-useless install, so it stays off.
if [ "${BOX_WITH_CUDA:-0}" = "1" ] && [ "${BOX_WITH_LLM:-0}" = "1" ]; then
  if [ -f /etc/apt/sources.list.d/cuda.list ]; then
    echo "The box has an NVIDIA GPU (CDI passthrough). Installing the CUDA toolkit and LLM runtimes..."
    echo "This is the large step - the CUDA toolkit (nvcc + cuBLAS) and the llama.cpp build dominate the time."

    # libcurl/OpenSSL are needed to build llama.cpp; zstd to unpack Ollama's
    # archive; build-essential + cmake for the llama.cpp compile. The NVIDIA
    # repo was registered earlier in this script, so a fresh update is needed
    # before the toolkit resolves.
    apt-get update -qq
    apt-get install -y cuda-toolkit-12-8 build-essential cmake pkg-config zstd libcurl4-openssl-dev \
      || echo "WARNING: could not install the CUDA toolkit/build deps - the LLM runtimes will be unavailable."

    # Expose nvcc (and the rest of the toolkit) on PATH for llama.cpp's cmake
    # to find; the cuda-* deb meta symlinks /usr/local/cuda to the payload.
    if [ -x /usr/local/cuda/bin/nvcc ]; then
      export PATH="/usr/local/cuda/bin:$PATH"
      echo "CUDA toolkit ready (nvcc $(/usr/local/cuda/bin/nvcc --version | sed -n '4p'))."
    fi
  else
    echo "Note: the NVIDIA CUDA repository is not registered (its keyring install failed earlier) - skipping the CUDA toolkit and LLM runtimes."
  fi

  # --- Ollama ---------------------------------------------------------------
  # The linux-amd64 release is two parts: the `ollama` CLI plus a `lib/ollama/`
  # tree that carries the llama-server runner and the CUDA runtime shared
  # objects, so it only needs the driver the CDI hook mounts - no toolkit at
  # runtime. Both parts must be installed together; the CLI locates the runner
  # under /usr/local/lib/ollama relative to its own /usr/local/bin path.
  # Debian has no ollama package, so vendor the upstream release archive with
  # the same pinned-version + SHA-256 approach as actionlint/runpodctl above.
  # The modern linux-amd64 asset is .tar.zst (the older .tgz URL is gone
  # upstream).
  #
  # TO BUMP: bump OLLAMA_VERSION, then fetch and verify the SHA from the
  # sha256sum.txt attached to that GitHub release:
  #   https://github.com/ollama/ollama/releases/download/vX.Y.Z/sha256sum.txt
  OLLAMA_VERSION="0.32.14"
  OLLAMA_SHA256="c620917a71e146ab3a7f893084f066069c4c65d144ef8379a91c3cbe8b27de8f"
  OLLAMA_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst"
  if command -v ollama >/dev/null 2>&1; then
    if [ "$(ollama --version 2>/dev/null)" = "ollama version is ${OLLAMA_VERSION}" ]; then
      echo "Ollama ${OLLAMA_VERSION} already installed."
    else
      OLLAMA_UPGRADE=1
    fi
  fi
  if [ -n "${OLLAMA_UPGRADE:-}" ] || ! command -v ollama >/dev/null 2>&1; then
    echo "Installing Ollama ${OLLAMA_VERSION}..."
    OLLAMA_TMP="$(mktemp -d)"
    if wget -qO "${OLLAMA_TMP}/ollama.tar.zst" "$OLLAMA_URL"; then
      if printf '%s  %s\n' "$OLLAMA_SHA256" "${OLLAMA_TMP}/ollama.tar.zst" \
          | sha256sum --check --status; then
        tar --zstd -xf "${OLLAMA_TMP}/ollama.tar.zst" -C "$OLLAMA_TMP"
        install -m 0755 "${OLLAMA_TMP}/bin/ollama" /usr/local/bin/ollama
        # The runner + CUDA libs in lib/ollama are mandatory at runtime - the
        # CLI errors "llama-server binary not found" without them. Copy the
        # whole tree so the shared objects and runner land where ollama looks.
        install -d /usr/local/lib/ollama
        cp -a "${OLLAMA_TMP}/lib/ollama"/. /usr/local/lib/ollama/ \
          || echo "WARNING: could not copy ollama runtime libs; models will fail to load with 'llama-server binary not found'."
        echo "Ollama ${OLLAMA_VERSION} installed."
      else
        echo "WARNING: Ollama checksum mismatch - refusing to install it."
      fi
    else
      echo "WARNING: could not download Ollama - skipping it."
    fi
    rm -rf "$OLLAMA_TMP"
  fi
  # Models land under $HOME/.ollama/models - the box's private home, not the
  # mounted repos dir - so they persist across rebuilds and stay out of your
  # on-disk repos.
  mkdir -p "$HOME/.ollama"
  # Provisioning runs as root, so this dir starts root-owned and Ollama would
  # fail to write its id_ed25519 key (and later, models) as the normal user.
  # Hand it to the box user like the other user home dirs above.
  chown -R "${BOX_USER}:${BOX_GID}" "$HOME/.ollama" 2>/dev/null || \
    echo "WARNING: could not chown $HOME/.ollama to ${BOX_USER}:${BOX_GID}; Ollama may fail to start for the user."

  # --- llama.cpp (CUDA build) ------------------------------------------------
  # llama.cpp publishes NO CUDA-enabled Linux prebuilt binary (upstream only
  # ships CUDA builds for Windows - its linux-x64 ubuntu tarball is CPU-only),
  # so to use the GPU it has to be compiled here with -DGGML_CUDA=ON, which is
  # what the CUDA toolkit above is for. Vendor the pinned SOURCE tarball (one
  # checksum covers every arch) and verify before extracting, like
  # watermarks-remover.
  #
  # TO BUMP: bump LLAMA_TAG, download
  #   https://github.com/ggml-org/llama.cpp/archive/refs/tags/<TAG>.tar.gz
  # and compute its sha256sum.
  LLAMA_TAG="b10488"
  LLAMA_SHA256="a006ca1a0268a3748686040d1ae021939d92ec0f58f341a30e52056298da4a0b"
  LLAMA_TAR="llama.cpp-${LLAMA_TAG}.tar.gz"
  if [ -x /usr/local/bin/llama-server ] && [ -x /usr/local/bin/llama-cli ]; then
    echo "llama.cpp ${LLAMA_TAG} already installed."
  elif [ -x /usr/local/cuda/bin/nvcc ] && command -v cmake >/dev/null 2>&1; then
    echo "Building llama.cpp ${LLAMA_TAG} with CUDA (first build compiles many kernels - be patient)..."
    LLAMA_TMP="$(mktemp -d)"
    if wget -qO "${LLAMA_TMP}/${LLAMA_TAR}" \
        "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMA_TAG}.tar.gz"; then
      if printf '%s  %s\n' "$LLAMA_SHA256" "${LLAMA_TMP}/${LLAMA_TAR}" \
          | sha256sum --check --status; then
        tar xzf "${LLAMA_TMP}/${LLAMA_TAR}" -C "$LLAMA_TMP" \
          --wildcards "llama.cpp-${LLAMA_TAG}/*"
        # Default to every major arch so a plain install works on any NVIDIA
        # GPU, not just the sm_86 on this box - slower to build, but portable.
        # Override with BOX_LLAMA_CUDA_ARCHS (e.g. '86') to build for one GPU.
        LLAMA_ARCHS="${BOX_LLAMA_CUDA_ARCHS:-all-major}"
        if cmake -S "${LLAMA_TMP}/llama.cpp-${LLAMA_TAG}" \
            -B "${LLAMA_TMP}/build" \
            -DGGML_CUDA=ON \
            -DCMAKE_CUDA_ARCHITECTURES="${LLAMA_ARCHS}" \
            -DCMAKE_BUILD_TYPE=Release >/dev/null; then
          if cmake --build "${LLAMA_TMP}/build" --config Release -j"$(nproc)" \
              --target llama-cli llama-server >"${LLAMA_TMP}/build.log" 2>&1; then
            mkdir -p /usr/local/bin
            install -m 0755 "${LLAMA_TMP}/build/bin/llama-cli" /usr/local/bin/llama-cli
            install -m 0755 "${LLAMA_TMP}/build/bin/llama-server" /usr/local/bin/llama-server
            echo "llama.cpp ${LLAMA_TAG} (CUDA) installed."
          else
            echo "WARNING: llama.cpp build failed - see ${LLAMA_TMP}/build.log. llama-cli/llama-server will be unavailable."
          fi
        else
          echo "WARNING: llama.cpp cmake configure failed - skipping the build."
        fi
      else
        echo "WARNING: llama.cpp source checksum mismatch - refusing to build it."
      fi
    else
      echo "WARNING: could not download llama.cpp source - skipping the build."
    fi
    rm -rf "$LLAMA_TMP"
  else
    echo "Note: llama.cpp build deps (nvcc/cmake) are unavailable - skipping the CUDA llama.cpp build."
  fi

  # --- CUDA Python (torch + vLLM) ---------------------------------------------
  # vLLM's PyPI wheel bundles its own CUDA libs; it needs torch that also has
  # CUDA, so torch is pulled first from PyTorch's CUDA 12.8 index and then
  # vLLM on top (pip respects the already-satisfied cu128 torch). On the
  # standalone 3.12 the watermark harnesses install, mirroring that venv
  # approach. `python -c 'import torch; torch.cuda.is_available()'` printing
  # True is the whole-pipeline GPU smoke test.
  if [ -x "/usr/local/lib/python-build-standalone/python/bin/python3.12" ]; then
    LLM_VENV="$HOME/llm-venv"
    if [ ! -d "$LLM_VENV" ]; then
      echo "Building the CUDA Python venv (torch is a large download on first run)..."
      /usr/local/lib/python-build-standalone/python/bin/python3.12 -m venv "$LLM_VENV"
      "$LLM_VENV/bin/pip" install --upgrade pip >/dev/null 2>&1
      "$LLM_VENV/bin/pip" install torch --index-url https://download.pytorch.org/whl/cu128 \
        || echo "WARNING: could not install CUDA torch - the LLM Python runtime will be unavailable."
      "$LLM_VENV/bin/pip" install vllm \
        || echo "WARNING: could not install vLLM - it will be unavailable (torch, if installed, still works)."
    fi
    # The venv is written as root during provisioning - hand it back to the box
    # user so vllm/the smoke test run without sudo (same fix as the harnesses).
    chown -R "${BOX_USER}:${BOX_GID}" "$LLM_VENV" 2>/dev/null || true
  else
    echo "Note: the standalone CPython 3.12 is unavailable - skipping the CUDA torch/vLLM venv."
  fi

  echo "CUDA LLM runtimes provisioned. Smoke-test inside the box with:"
  echo "  nvidia-smi   # should list your GPU"
  echo "  \"$HOME/llm-venv/bin/python\" -c 'import torch; print(torch.cuda.is_available())'"
fi

# Start-on-demand wrapper. Root-owned and world-executable: the box user's
# shell (and the remove-ai-marks skill) invoke it, so it must not need root or
# a write to /usr/local at runtime - it only reads and starts the service.
cat > /usr/local/bin/watermarks-serve <<'WMSERVE_WRAPPER'
#!/usr/bin/env bash
# Idempotent start wrapper for the watermarks-remover service. The service
# must live inside this container (private network namespace - a host-side
# service on 127.0.0.1 is unreachable from here), so this checks the health
# endpoint and starts the python stdlib server on demand when it is down.
set -euo pipefail

HEALTH="http://127.0.0.1:8765/health"
if curl -sf "$HEALTH" >/dev/null 2>&1; then
  exit 0
fi

# Expose the same-scheme harness backends (if present) to the service. server.py
# reads these from the process environment once at startup, so they must be set
# before the service launches. Harmless if provisioning skipped them.
[ -d "$HOME/MarkLLM" ] && export MARKLLM_DIR="$HOME/MarkLLM"
[ -d "$HOME/reverse-SynthID" ] && export REVERSE_SYNTHID_DIR="$HOME/reverse-SynthID"

nohup python3 /usr/local/lib/watermarks-remover/server.py \
  --host 127.0.0.1 --port 8765 \
  </dev/null >>/tmp/watermarks-serve.log 2>&1 &
disown 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if curl -sf "$HEALTH" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.5
done

echo "watermarks-remover service did not come up - see /tmp/watermarks-serve.log" >&2
exit 1
WMSERVE_WRAPPER
chmod 0755 /usr/local/bin/watermarks-serve

echo "Container provisioning complete."
