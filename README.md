# vscodium-for-immutable

One script that provisions a working development environment on immutable
Fedora hosts (Bazzite, Silverblue, Kinoite, and similar), where you can't
install `.deb`/`.rpm` packages onto the base OS.

It installs **VSCodium** from its official `.deb` package into a Distrobox
container, along with the tools you actually need next to an editor: **git**,
the **GitHub CLI**, **Claude Code**, and a lint toolchain (**shellcheck**,
**actionlint**, **jq**, **fd**, **yamllint**). The editor is then exported to the host
application menu and launches like any native app.

Because VSCodium's integrated terminal runs inside that container, everything
the script installs is already on PATH there. That is the point of the design:
the environment is defined by this one script, so it is reproducible and
survives a container rebuild. If you need a new tool, add it here rather than
installing it by hand into the container.

It's a sibling to
[claude-desktop-for-immutable](https://github.com/Kinsman4249/claude-desktop-for-immutable)
and uses the same approach, but deliberately ships **none** of that project's
Cowork/QEMU virtualization tooling - VSCodium doesn't need it.

## Why

Immutable Fedora variants keep the base OS read-only, so you can't just
`apt`/`dnf install` a desktop app. The clean workaround is to run it inside a
[Distrobox](https://github.com/89luca89/distrobox) container (a normal Debian
userland) and export its launcher to the host. VSCodium publishes `.deb`
packages via an apt repo, which is a perfect fit.

### Why not Homebrew or Flatpak?

Both are the usual answers for "installing a Linux desktop app without
touching the base OS," and both fall short here:

- **Homebrew** doesn't actually have a Linux VSCodium package. The official
  `vscodium` cask on [formulae.brew.sh](https://formulae.brew.sh/cask/vscodium)
  is macOS-only; on Linux you're pointed at unofficial third-party taps that
  build from source, with no binary or signature backed by the VSCodium
  project itself.
- **Flatpak** does ship an official `com.vscodium.codium` on Flathub, but its
  sandbox works against a dev editor: the
  [flathub.vscodium README](https://github.com/daiyam/flathub.vscodium.stable/blob/master/README.md)
  states plainly that it "is not able to access SDKs on your host system," so
  each language toolchain needs its own separate Flatpak SDK extension
  (`org.freedesktop.Sdk.Extension.dotnet`, `.golang`, etc.), enabled per-launch
  via an env var - and coverage is still partial.

This project's Distrobox container is a normal, unsandboxed Debian userland,
so VSCodium gets the real official `.deb` (same binaries/signing as upstream's
own apt repo) plus unrestricted access to whatever toolchains you install in
the container or reach via `distrobox` commands - no per-language SDK
extensions, no sandbox permission wrangling.

## What the installer does

1. Creates a Debian 12 Distrobox container named `vscodium-box` (reused on
   later runs).
2. Adds VSCodium's official apt repository (from `vscodium.com`) with a pinned
   signing key, and installs the `codium` package.
3. Also installs **git** and the **GitHub CLI (`gh`)** inside the container,
   from GitHub's official apt repo, so VSCodium's source control and any
   terminal/agent workflows have them on PATH.
4. Installs a small lint toolchain alongside them: **shellcheck**, **jq**,
   **fd** (Debian names the binary `fdfind`, so a `fd` symlink is added),
   **yamllint**, and **actionlint**. The first four come from Debian; Debian
   has no actionlint package, so its upstream release binary is downloaded
   and checked against a SHA-256 pinned in the script. A checksum mismatch
   skips actionlint and leaves the rest of the install untouched.
5. Installs **Claude Code** from Anthropic's signed apt repository (`stable`
   channel), rather than the `curl | bash` one-liner the
   [docs](https://code.claude.com/docs/en/setup) lead with, so it is pinned to
   a signing key like everything else here and upgrades with the rest of the
   container. The key's published fingerprint is verified before it is
   trusted; a mismatch skips Claude Code and leaves the rest of the install
   untouched. Run `claude` in VSCodium's terminal and log in on first use.
5. Symlinks `distrobox` -> `distrobox-host-exec` at `/usr/local/bin/distrobox`
   *inside* the container, so running `distrobox ...` from VSCodium's
   integrated terminal forwards to your real host distrobox instead of
   silently doing nothing (the container has no podman/docker of its own).
   See "Running distrobox from VSCodium's terminal" below.
6. Exports VSCodium to the host application launcher via `distrobox-export`.
7. Adds `--disable-gpu-compositing` to the exported launcher to work around an
   Electron GPU-process repaint bug seen on hybrid Intel+NVIDIA hardware. See
   "GPU note" below if you don't need it.
8. Installs VSCodium's icon into the host's `hicolor` icon theme
   (`~/.local/share/icons/hicolor/512x512/apps/vscodium.png`) and points the
   launcher's `Icon=` at it by name, so it shows up correctly in both the
   app grid/start menu and the taskbar/dock (an earlier version pointed
   `Icon=` at an absolute file path, which most taskbars can't resolve).

## Prerequisites

- An immutable (or any) Fedora host with **Distrobox** and a container backend
  (podman or docker) installed.
- Network access to `download.vscodium.com`, `gitlab.com`,
  `cli.github.com`, and `github.com` (the last one for the actionlint
  release binary).

## Usage

```bash
./install-vscodium.sh            # install, or update if already installed
./install-vscodium.sh --debug    # same, but print every command run
./install-vscodium.sh --remove   # uninstall: drop the exported app + container
./install-vscodium.sh --help     # show help
```

Re-running the installer updates VSCodium (and git/gh, Claude Code, and the
lint toolchain) in place. Claude Code installed from apt does not update
itself, so a re-run is how it moves forward. actionlint is skipped on a re-run if the pinned version
is already installed, so repeat runs stay cheap.

## Running distrobox from VSCodium's terminal

VSCodium's integrated terminal runs inside the `vscodium-box` container, which
has no `podman`/`docker` or access to the host's container runtime. Running
`distrobox` commands there directly would either fail or do nothing useful -
it's not a nested/docker-in-docker situation, there's just no backend inside
the container to talk to.

The installer works around this by symlinking `distrobox` inside the
container to [`distrobox-host-exec`](https://distrobox.it/usage/distrobox-host-exec/),
a tool distrobox ships for exactly this purpose: it forwards a command to run
on the real host. So `distrobox list`, `distrobox enter foo`, etc. typed in
VSCodium's terminal act on your actual host containers, not on `vscodium-box`
itself.

## GPU note

The installer adds `--disable-gpu-compositing` to VSCodium's launcher because
that fixed garbled/ghosted text on the hybrid Intel+NVIDIA laptop this was
built for. If your VSCodium renders correctly without it, remove that token
from the `Exec=` line in
`~/.local/share/applications/vscodium-box-codium.desktop` **and** delete the
`sed` line in `patch_launcher_flags` (otherwise it's re-applied on the next
run).

## Testing changes

After editing `install-vscodium.sh`, run both checks - the installer provides
shellcheck itself, so there is no excuse to skip it:

```bash
bash -n install-vscodium.sh    # syntax
shellcheck install-vscodium.sh # correctness
```

Then do a full `./install-vscodium.sh` and confirm VSCodium launches from the
app grid, its integrated terminal has `git`, `gh`, `actionlint`, and `claude`
(check with `claude --version`), and
`./install-vscodium.sh --remove` tears everything down cleanly.

Note that the toolchain lives inside the inner heredoc that runs in the
container, so `shellcheck` on the outer file does not see it. To check that
part, extract it first:

```bash
awk '/^  cat > "\$out" <<.INNER.$/{f=1;next} /^INNER$/{f=0} f' \
  install-vscodium.sh | shellcheck -s bash -
```

## License

See [LICENSE](LICENSE).
