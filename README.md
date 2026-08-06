# vscodium-for-immutable

A one-click installer that runs **VSCodium** from its official `.deb` package
on immutable Fedora hosts (Bazzite, Silverblue, Kinoite, and similar) where
you can't install `.deb`/`.rpm` packages onto the base OS.

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

## What the installer does

1. Creates a Debian 12 Distrobox container named `vscodium-box` (reused on
   later runs).
2. Adds VSCodium's official apt repository (from `vscodium.com`) with a pinned
   signing key, and installs the `codium` package.
3. Also installs **git** and the **GitHub CLI (`gh`)** inside the container,
   from GitHub's official apt repo, so VSCodium's source control and any
   terminal/agent workflows have them on PATH.
4. Exports VSCodium to the host application launcher via `distrobox-export`.
5. Adds `--disable-gpu-compositing` to the exported launcher to work around an
   Electron GPU-process repaint bug seen on hybrid Intel+NVIDIA hardware. See
   "GPU note" below if you don't need it.

## Prerequisites

- An immutable (or any) Fedora host with **Distrobox** and a container backend
  (podman or docker) installed.
- Network access to `download.vscodium.com`, `gitlab.com`, and
  `cli.github.com`.

## Usage

```bash
./install-vscodium.sh            # install, or update if already installed
./install-vscodium.sh --debug    # same, but print every command run
./install-vscodium.sh --remove   # uninstall: drop the exported app + container
./install-vscodium.sh --help     # show help
```

Re-running the installer updates VSCodium (and git/gh) in place.

## GPU note

The installer adds `--disable-gpu-compositing` to VSCodium's launcher because
that fixed garbled/ghosted text on the hybrid Intel+NVIDIA laptop this was
built for. If your VSCodium renders correctly without it, remove that token
from the `Exec=` line in
`~/.local/share/applications/vscodium-box-codium.desktop` **and** delete the
`sed` line in `patch_launcher_flags` (otherwise it's re-applied on the next
run).

## Testing changes

After editing `install-vscodium.sh`, at minimum run `bash -n
install-vscodium.sh` to syntax-check it, then do a full `./install-vscodium.sh`
and confirm VSCodium launches from the app grid, its integrated terminal has
`git` and `gh`, and `./install-vscodium.sh --remove` tears everything down
cleanly.

## License

See [LICENSE](LICENSE).
