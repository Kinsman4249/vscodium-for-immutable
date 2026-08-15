# vscodium-for-immutable

One script that provisions a working development environment on immutable
Fedora hosts (Bazzite, Silverblue, Kinoite, and similar), where you can't
install `.deb`/`.rpm` packages onto the base OS.

It installs **VSCodium** from its official `.deb` package into a rootless
**podman** container, along with the tools you actually need next to an editor:
**git**, the **GitHub CLI**, **DeepSeek Harness**, **Chromium**, and a lint
toolchain (**shellcheck**, **actionlint**, **jq**, **fd**, **yamllint**).
**Claude Code** is available too, opt-in via `--claude`. The script then
writes a launcher and a `.desktop` entry on the host, so the editor starts
from the app grid like any native app.

Because VSCodium's integrated terminal runs inside that container, everything
the script installs is already on PATH there. That is the point of the design:
the environment is defined by this one script, so it is reproducible and
survives a container rebuild. If you need a new tool, add it here rather than
installing it by hand into the container.

The container is deliberately scoped: it can see the one repos directory you
give it, its own private home, and the X11 socket (or, if you ask for it,
`/dev/dri` and the Wayland socket). Nothing else of yours. See
[What the container can and cannot reach](#what-the-container-can-and-cannot-reach).

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

Every path from the container to the host is one of these, and nothing else:

| Mount/device | Mode | Why | On by default? |
| --- | --- | --- | --- |
| your `--repos-dir` | read-write | the code you actually want to edit | yes, required |
| `~/.local/state/vscodium-box/home` | read-write | the container's private home: settings, extensions, dotfiles, DeepSeek Harness / Claude Code auth | yes |
| the X11 socket (XWayland) | read-only | so a window can be drawn | yes |
| `/dev/dri` | read-write | GPU-accelerated rendering instead of software fallback | yes, if present (pass `--no-gpu` to opt out) |
| the Wayland socket | read-only | native Wayland instead of XWayland | no (pass `--wayland`; see [Wayland note](#wayland-note)) |
| a `--publish` port | host `127.0.0.1` only | reach a dev server started inside the box | no |

The private home is mounted at the same path as your host home, so `~` and
absolute paths behave normally inside the container - but its contents are that
state directory, not your home.

**Never** mounted or shared, with no flag that changes it: your host home, the
host filesystem (no `/run/host`), host `/tmp`, any device other than
`/dev/dri`, the host D-Bus session, the host PID and IPC namespaces, or the
host network namespace (a `--publish` port is forwarded in, not a shared
namespace). The container also never runs `--privileged` and is never given
`--security-opt label=disable`, so SELinux confinement (mounts are relabeled
with `z`) stays enforced against it exactly as it would against any other
process on the host.

Consequences of that scoping, which are real trade-offs and not oversights:

- **No `distrobox`/host-exec from the terminal.** The old setup symlinked
  `distrobox` to `distrobox-host-exec` so terminal commands could run on the
  host. That is a direct escape hatch out of the container and is gone on
  purpose.
- **No host browser, notifications, or portals.** Without a D-Bus session
  socket there is no `xdg-desktop-portal`, so clicking a link in VSCodium will
  not open your host browser. `gh auth login` still works; with no secret
  service it stores the token in its own config file, inside the container's
  private home.
- **Ports are not shared with the host.** Outbound networking works, but a dev
  server you start inside the box is not reachable from a host browser unless
  you pass `--publish PORT` at install time (it is published on `127.0.0.1`
  only).
- **Run the installer from a host terminal.** Not from VSCodium's integrated
  terminal - the container has no way back to the host any more.

None of this makes the container safe to run untrusted code in - it makes the
blast radius small and explicit. Everything the container *can* reach, assume
a hostile process inside it can and will abuse: it can rewrite anything in
your repos directory, including git history and hooks, and can use whatever
credentials live in its private home (DeepSeek Harness's / Claude Code's auth,
`gh`'s token). What scoping the mounts buys you is that a compromise stops there - it does not
also get your dotfiles, your SSH keys, your other repos, your other devices,
or a route back out to the rest of the host.

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
   container - but only if `--claude` was passed. Off by default. Run `claude`
   in VSCodium's terminal and log in on first use.
7. Installs **Node.js and npm** from Debian's own repo (no extra signing key
   needed for that one), then installs **DeepSeek Harness**
   (`@deepseek-ai/dsh`) from npm - it's Node-based and has no apt/dnf/apk repo
   of its own. This is the default agent harness; still a developer preview,
   so expect breaking changes upstream. Run `dsh web` in VSCodium's terminal
   and log in on first use.
8. Installs **Chromium** from Debian's own repo (no extra signing key needed
   for that one). This is a plain browser for sites that gate login behind a
   WebAuthn/passkey prompt handled entirely in-browser JS - it does not wire
   up a physical security key (YubiKey/FIDO2 USB), since that would need
   `/dev/hidraw` or `/dev/bus/usb` passed into the container, which this
   script does not do.
9. Writes a launcher at `~/.local/bin/vscodium-box` and a `.desktop` entry at
   `~/.local/share/applications/vscodium-box.desktop` on the host. Neither is
   reachable from inside the container, so a process in there cannot rewrite
   the thing you click on.
10. Writes a second launcher/`.desktop` pair the same way -
    `~/.local/bin/vscodium-box-console` and `vscodium-box Console` in your app
    grid - that drops into a raw shell in the container instead of starting
    VSCodium. Useful for checking what a CLI tool installed inside the
    container (Cline, Kilo Code, DeepSeek Harness, etc.) actually sees,
    without going through the editor's integrated terminal.
11. Adds `--disable-gpu-compositing` to the launcher's command line
    unconditionally, and `--disable-gpu` too if `/dev/dri` isn't available (or
    `--no-gpu` was passed). See [GPU note](#gpu-note) below.
12. Installs VSCodium's icon into the host's `hicolor` icon theme
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
- **DeepSeek Harness**: installed from npm, not an apt repo, so there is no
  signing key to pin here at all - npm's own registry integrity checks are the
  only verification. It is also a fresh developer preview (first released
  2026-08-13), so treat it accordingly.

## Prerequisites

- A Fedora host (immutable or not) with rootless **podman**. Bazzite,
  Silverblue and Kinoite all ship it.
- An X11 or XWayland session (the default), or a Wayland session if you're
  going to pass `--wayland` - see the [Wayland note](#wayland-note) first.
- Network access to `download.vscodium.com`, `gitlab.com`, `cli.github.com`,
  `registry.npmjs.org` (DeepSeek Harness), `github.com` (the actionlint
  release binary), Debian's mirrors, and, if you pass `--claude`,
  `downloads.claude.ai`.

## Usage

Run these from a **host** terminal:

```bash
./install-vscodium.sh --repos-dir ~/github   # install, scoped to that directory
./install-vscodium.sh                        # update, reusing the saved repos dir
./install-vscodium.sh --wayland              # use native Wayland instead of XWayland
./install-vscodium.sh --no-gpu               # force software rendering
./install-vscodium.sh --publish 3000         # publish a port on 127.0.0.1
./install-vscodium.sh --claude               # also install Claude Code
./install-vscodium.sh --debug                # print every command run
./install-vscodium.sh --help                 # show help

./uninstall-vscodium.sh                      # uninstall: container + launcher
./uninstall-vscodium.sh --debug              # print every command run
./uninstall-vscodium.sh --help               # show help
```

`uninstall-vscodium.sh` also sweeps up anything a prior version of this project
could have left behind, including the old Distrobox `vscodium-box` container
and its exported `.desktop` file and icon - see
[Migrating from the Distrobox versions](#migrating-from-the-distrobox-versions)
below.

`--repos-dir` is required the first time and is saved to
`~/.config/vscodium-box/repos-dir` for later runs. It must be a directory under
your home, and the script refuses `/`, `$HOME` itself, and other paths that
would defeat the point. `--repos-dir`, `--wayland`, `--no-gpu`/`--gpu` and
`--publish` are fixed when the container is created; changing them means
`./uninstall-vscodium.sh` followed by a fresh install. (`--gpu` and `--x11` are
still accepted - they're just the defaults now, kept as no-ops so old habits
and scripts don't break.)

Re-running the installer updates VSCodium (and git/gh, DeepSeek Harness,
Chromium, and the lint toolchain) in place. Pass `--claude` again on a re-run
to also update Claude Code - it isn't remembered between runs, unlike
`--repos-dir`. Neither Claude Code (apt) nor DeepSeek Harness (npm) update
themselves, so a re-run is how they move forward. actionlint is skipped on a
re-run if the pinned version is already installed, so repeat runs stay cheap.

### Migrating from the Distrobox versions

If you still have the old Distrobox `vscodium-box`, the installer stops and
tells you what to run. Its settings and extensions live inside that container
and go away with it; the new container starts with a fresh private home:

```bash
./uninstall-vscodium.sh
./install-vscodium.sh --repos-dir ~/github
```

## Wayland note

Native Wayland (`--wayland`) is not the default because, on the host this was
tested on (KDE Plasma 6.7, KWin's Wayland compositor), it crashes Electron
deterministically: VSCodium binds `zwp_linux_dmabuf_v1` version 4, KWin offers
version 5, and Electron's handling of that protocol's `format_table` event
segfaults within a minute or two of the window opening. This reproduces with
or without `--no-gpu`, so it isn't a rendering-path issue - Ozone still binds
that protocol for clipboard/drag-and-drop even with GPU compositing off. It
looks like a genuine version-negotiation bug in the bundled Electron/Chromium
build against newer KWin, not something a container flag can work around.
XWayland (the default) uses the older, stable X11 Ozone backend and doesn't
hit this path at all.

If you still want to try native Wayland - a different compositor may not have
the bug - be aware it also needs a **separate SELinux allow rule** beyond what
this script's mounts provide: connecting to the compositor's socket is a
process-to-process `connectto` check (`unix_stream_socket`), independent of
the file-level relabel the `,z` mount option already handles, and no stock
`setsebool` boolean covers it on Fedora's current policy. Without it you'll
see the socket as unreadable and Electron will exit silently. Generate the
rule from the real denial rather than guessing:

```bash
sudo ausearch -m avc -ts recent | grep connectto > avc.log
audit2allow -M vscodium_box_wayland -i avc.log
sudo semanage module -a vscodium_box_wayland.pp
```

This is a standing host-level policy change - it's not undone by
`./uninstall-vscodium.sh` and isn't scoped to this container specifically, just
to that one `connectto` class. Remove it with
`sudo semanage module -r vscodium_box_wayland` if you stop using `--wayland`.

## GPU note

The launcher always passes `--disable-gpu-compositing`, GPU or not, because
that fixed garbled/ghosted text on the hybrid Intel+NVIDIA laptop this was
built for - it's a repaint bug in the GPU *process*, not GPU access itself.
`/dev/dri` is passed through by default when present, so rendering still uses
real hardware; pass `--no-gpu` at install time to force full software
rendering (`--disable-gpu` as well) instead. If your VSCodium renders
correctly without the compositing flag, remove that token from the
`exec podman exec` line in `~/.local/bin/vscodium-box` **and** from
`write_launcher` in `install-vscodium.sh` (otherwise it's re-applied on the
next run).

## Testing changes

There are three scripts: `install-vscodium.sh` and `uninstall-vscodium.sh` run
on the host, and `provision-container.sh` is piped into the container as root.
Check all three - the installer provides shellcheck itself, so there is no
excuse to skip it:

```bash
bash -n install-vscodium.sh uninstall-vscodium.sh provision-container.sh
shellcheck install-vscodium.sh uninstall-vscodium.sh provision-container.sh
```

Then, from a host terminal, install against a throwaway directory first and
verify the mount set is what it claims to be:

```bash
./install-vscodium.sh --repos-dir ~/scratch-repos --debug
podman inspect vscodium-box \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

That must list exactly the container home, the repos directory, and the X11
socket (plus the Wayland socket if you passed `--wayland`). Then confirm from
inside (`podman exec -it vscodium-box bash`) that `/run/host` does not exist,
that `~` is the private home and not yours, and that a symlink planted in the
repos directory pointing at `~/.ssh` dangles.

Finally, launch VSCodium from the app grid and check that the icon appears in
the taskbar and that its integrated terminal has `git`, `gh`, `actionlint`,
`fd`, and `dsh` (check with `dsh --version`) - and, if you passed `--claude`,
`claude` (`claude --version`) too. Launch "vscodium-box Console" from the app
grid too and check that it opens a bare shell in the same container (`echo
$HOME` should print the container's real home path, not start VSCodium).
Then confirm that `./uninstall-vscodium.sh` tears everything down cleanly.

## License

See [LICENSE](LICENSE).
