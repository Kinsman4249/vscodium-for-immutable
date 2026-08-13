# vscodium-for-immutable

One script that provisions a working development environment on immutable
Fedora hosts (Bazzite, Silverblue, Kinoite, and similar), where you can't
install `.deb`/`.rpm` packages onto the base OS.

It installs **VSCodium** from its official `.deb` package into a rootless
**podman** container, along with the tools you actually need next to an editor:
**git**, the **GitHub CLI**, **Claude Code**, and a lint toolchain
(**shellcheck**, **actionlint**, **jq**, **fd**, **yamllint**). The script then
writes a launcher and a `.desktop` entry on the host, so the editor starts from
the app grid like any native app.

Because VSCodium's integrated terminal runs inside that container, everything
the script installs is already on PATH there. That is the point of the design:
the environment is defined by this one script, so it is reproducible and
survives a container rebuild. If you need a new tool, add it here rather than
installing it by hand into the container.

The container is deliberately scoped: it can see the one repos directory you
give it, its own private home, and the Wayland socket. Nothing else of yours.
See [What the container can and cannot reach](#what-the-container-can-and-cannot-reach).

It's a sibling to
[claude-desktop-for-immutable](https://github.com/Kinsman4249/claude-desktop-for-immutable)
and uses the same approach, but deliberately ships **none** of that project's
Cowork/QEMU virtualization tooling - VSCodium doesn't need it.

## Why

Immutable Fedora variants keep the base OS read-only, so you can't just
`apt`/`dnf install` a desktop app. The clean workaround is to run it inside a
container with a normal Debian userland and put a launcher for it on the host.
VSCodium publishes `.deb` packages via an apt repo, which is a perfect fit.

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

The container here is a normal Debian userland, so VSCodium gets the real
official `.deb` (same binaries and signing as upstream's own apt repo) and any
toolchain you install alongside it - no per-language SDK extensions, no
per-launch permission wrangling. What is restricted is which of *your files* it
can touch, not which tools it can run.

### Why not Distrobox?

Earlier versions of this project used [Distrobox](https://github.com/89luca89/distrobox),
and it worked well, but it cannot give the container scoped access to your
files, which is now a goal of this project. Distrobox always:

- bind-mounts your entire host `$HOME` at its real path, unconditionally. Its
  own documentation says the `--home` flag "will NOT prevent the mount of the
  host's home directory"
  ([docs/usage/distrobox-create.md](https://github.com/89luca89/distrobox/blob/main/docs/usage/distrobox-create.md#L208));
- mounts all of `/` at `/run/host`, read-write for every writable top-level
  directory, and no `--unshare-*` flag removes it
  ([pkg/containermanager/providers/podman.go](https://github.com/89luca89/distrobox/blob/main/pkg/containermanager/providers/podman.go#L257));
- runs the container `--privileged` with SELinux and AppArmor confinement
  turned off, and shares the host's `/tmp`, PID, IPC and network namespaces.

That is a reasonable set of defaults for the problem Distrobox solves. It is
the wrong set for running a code editor plus a coding agent plus third-party
extensions, where the interesting question is what a compromised process inside
the box can reach on the way out. So this project now drives podman directly.

## What the container can and cannot reach

Three bind mounts, and that is the entire list:

| Mount | Mode | Why |
| --- | --- | --- |
| your `--repos-dir` | read-write | the code you actually want to edit |
| `~/.local/state/vscodium-box/home` | read-write | the container's private home: settings, extensions, dotfiles, Claude Code auth |
| the Wayland socket | read-only | so a window can be drawn |

The private home is mounted at the same path as your host home, so `~` and
absolute paths behave normally inside the container - but its contents are that
state directory, not your home.

**Not** mounted or shared: your host home, the host filesystem (no `/run/host`),
host `/tmp`, host devices (`/dev`, `/sys`), the host D-Bus session, the host PID
and IPC namespaces, or the host network namespace. The container is not
privileged and SELinux confinement stays on (mounts are relabeled with `z`).

Consequences of that, which are real trade-offs and not oversights:

- **No `distrobox`/host-exec from the terminal.** The old setup symlinked
  `distrobox` to `distrobox-host-exec` so terminal commands could run on the
  host. That is a direct escape hatch out of the container and is gone on
  purpose.
- **No host browser, notifications, or portals.** Without a D-Bus session
  socket there is no `xdg-desktop-portal`, so clicking a link in VSCodium will
  not open your host browser. `gh auth login` still works; with no secret
  service it stores the token in its own config file, inside the container's
  private home.
- **Software rendering by default.** No `/dev/dri` means Electron falls back to
  SwiftShader. Pass `--gpu` at install time to expose `/dev/dri` if you want
  hardware rendering.
- **Ports are not shared with the host.** Outbound networking works, but a dev
  server you start inside the box is not reachable from a host browser unless
  you pass `--publish PORT` at install time (it is published on `127.0.0.1`
  only).
- **Run the installer from a host terminal.** Not from VSCodium's integrated
  terminal - the container has no way back to the host any more.

Everything the container *can* reach, it can still do damage to: assume a
hostile process in there can rewrite anything in your repos directory,
including git history and hooks, and can use whatever credentials live in its
private home. Scoping the mounts limits the blast radius; it does not make the
container safe to run untrusted code in.

## What the installer does

1. Creates a Debian 12 container named `vscodium-box` with rootless podman
   (reused on later runs), with only the mounts listed above.
2. Creates an account inside it matching your host uid/gid (via
   `--userns keep-id`), so files written into your repos directory keep the
   right ownership on the host side.
3. Adds VSCodium's official apt repository (from `vscodium.com`) with a pinned
   signing key, and installs the `codium` package.
4. Also installs **git** and the **GitHub CLI (`gh`)** inside the container,
   from GitHub's official apt repo, so VSCodium's source control and any
   terminal/agent workflows have them on PATH.
5. Installs a small lint toolchain alongside them: **shellcheck**, **jq**,
   **fd** (Debian names the binary `fdfind`, so a `fd` symlink is added),
   **yamllint**, and **actionlint**. The first four come from Debian; Debian
   has no actionlint package, so its upstream release binary is downloaded
   and checked against a SHA-256 pinned in the script. A checksum mismatch
   skips actionlint and leaves the rest of the install untouched.
6. Installs **Claude Code** from Anthropic's signed apt repository (`stable`
   channel), rather than the `curl | bash` one-liner the
   [docs](https://code.claude.com/docs/en/setup) lead with, so it is pinned to
   a signing key like everything else here and upgrades with the rest of the
   container. Run `claude` in VSCodium's terminal and log in on first use.
7. Writes a launcher at `~/.local/bin/vscodium-box` and a `.desktop` entry at
   `~/.local/share/applications/vscodium-box.desktop` on the host. Neither is
   reachable from inside the container, so a process in there cannot rewrite
   the thing you click on.
8. Adds `--disable-gpu` (unless `--gpu` was passed) and
   `--disable-gpu-compositing` to the launcher's command line. The second works
   around an Electron GPU-process repaint bug seen on hybrid Intel+NVIDIA
   hardware; see "GPU note" below.
9. Installs VSCodium's icon into the host's `hicolor` icon theme
   (`~/.local/share/icons/hicolor/512x512/apps/vscodium.png`) and points the
   launcher's `Icon=` at it by name, so it shows up correctly in both the
   app grid/start menu and the taskbar/dock (an earlier version pointed
   `Icon=` at an absolute file path, which most taskbars can't resolve).

### Signing key trust

All three apt repositories are pinned to a dedicated keyring with `signed-by`,
**and** the key's primary fingerprints are checked before the key is installed.
The check requires that *every* primary key in the downloaded file is one this
script expects, so an extra key cannot be smuggled into a file that still
contains the legitimate one. A download failure or a fingerprint mismatch warns,
skips that repository, and leaves the rest of the install alone.

What that pin is worth differs per repository, and the script says so in
comments:

- **GitHub CLI**: GitHub publishes the fingerprints in
  [docs/install_linux.md](https://github.com/cli/cli/blob/trunk/docs/install_linux.md),
  so this is a genuine second channel. Fingerprints are pinned rather than the
  published SHA-256 of the keyring file, because that file carries two keys and
  the older one expires in early 2027, so the file itself will change.
- **Claude Code**: Anthropic publishes the fingerprint in its
  [setup docs](https://code.claude.com/docs/en/setup). Same deal.
- **VSCodium**: upstream publishes no fingerprint anywhere, and the key comes
  from the same URL the install instructions point at, so the pin here is
  **change detection, not an independent trust anchor**. It catches a later key
  rotation or a tampered response; it cannot tell you the key was ever right.

## Prerequisites

- A Fedora host (immutable or not) with rootless **podman**. Bazzite,
  Silverblue and Kinoite all ship it.
- A Wayland session (or pass `--x11` to use XWayland instead).
- Network access to `download.vscodium.com`, `gitlab.com`, `cli.github.com`,
  `downloads.claude.ai`, `github.com` (the actionlint release binary), and
  Debian's mirrors.

## Usage

Run these from a **host** terminal:

```bash
./install-vscodium.sh --repos-dir ~/github   # install, scoped to that directory
./install-vscodium.sh                        # update, reusing the saved repos dir
./install-vscodium.sh --gpu                  # also expose /dev/dri (creation only)
./install-vscodium.sh --x11                  # use XWayland instead of Wayland
./install-vscodium.sh --publish 3000         # publish a port on 127.0.0.1
./install-vscodium.sh --debug                # print every command run
./install-vscodium.sh --remove               # uninstall container + launcher
./install-vscodium.sh --help                 # show help
```

`--repos-dir` is required the first time and is saved to
`~/.config/vscodium-box/repos-dir` for later runs. It must be a directory under
your home, and the script refuses `/`, `$HOME` itself, and other paths that
would defeat the point. `--repos-dir`, `--gpu`, `--x11` and `--publish` are
fixed when the container is created; changing them means
`./install-vscodium.sh --remove` followed by a fresh install.

Re-running the installer updates VSCodium (and git/gh, Claude Code, and the
lint toolchain) in place. Claude Code installed from apt does not update itself,
so a re-run is how it moves forward. actionlint is skipped on a re-run if the
pinned version is already installed, so repeat runs stay cheap.

### Migrating from the Distrobox versions

If you still have the old Distrobox `vscodium-box`, the installer stops and
tells you what to run. Its settings and extensions live inside that container
and go away with it; the new container starts with a fresh private home:

```bash
distrobox rm --force vscodium-box
rm -f ~/.local/share/applications/vscodium-box-codium.desktop
./install-vscodium.sh --repos-dir ~/github
```

## GPU note

The launcher passes `--disable-gpu-compositing` because that fixed
garbled/ghosted text on the hybrid Intel+NVIDIA laptop this was built for, and
`--disable-gpu` because there is no `/dev/dri` in the container unless you asked
for it with `--gpu`. If your VSCodium renders correctly without the compositing
flag, remove that token from the `exec podman exec` line in
`~/.local/bin/vscodium-box` **and** from `write_launcher` in
`install-vscodium.sh` (otherwise it's re-applied on the next run).

## Testing changes

There are two scripts: `install-vscodium.sh` runs on the host, and
`provision-container.sh` is piped into the container as root. Check both - the
installer provides shellcheck itself, so there is no excuse to skip it:

```bash
bash -n install-vscodium.sh provision-container.sh
shellcheck install-vscodium.sh provision-container.sh
```

Then, from a host terminal, install against a throwaway directory first and
verify the mount set is what it claims to be:

```bash
./install-vscodium.sh --repos-dir ~/scratch-repos --debug
podman inspect vscodium-box \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

That must list exactly the container home, the repos directory, and the Wayland
socket. Then confirm from inside (`podman exec -it vscodium-box bash`) that
`/run/host` does not exist, that `~` is the private home and not yours, and that
a symlink planted in the repos directory pointing at `~/.ssh` dangles.

Finally, launch VSCodium from the app grid and check that the icon appears in
the taskbar and that its integrated terminal has `git`, `gh`, `actionlint`,
`fd`, and `claude` (check with `claude --version`) - then that
`./install-vscodium.sh --remove` tears everything down cleanly.

## License

See [LICENSE](LICENSE).
