# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-08-06

### Added

- The installer now provisions a lint toolchain inside `vscodium-box` alongside VSCodium, git, and gh: shellcheck, jq, fd, yamllint, and actionlint. The first four come from Debian's own repositories. Debian names the fd binary `fdfind`, because the name `fd` was already taken by an unrelated package, so the installer adds an `fd` symlink in `/usr/local/bin` to match the name used in nearly all fd documentation. That location is deliberate: `$HOME` is bind-mounted into the container, so a symlink under `~/.local/bin` would also appear on the host's PATH, which is the same reasoning already applied to the `distrobox` shim.
- actionlint is installed from its upstream GitHub release binary, since Debian 12 carries no actionlint package. There is no signing key to pin against as there is for the VSCodium and GitHub CLI apt repositories, so the trust anchor is an explicit SHA-256 checksum of the exact release tarball, pinned in the script for both amd64 and arm64. The checksum is verified before the archive is unpacked. A mismatch or a failed download logs a warning, skips actionlint, and leaves the rest of the installation untouched rather than aborting it. Re-running the installer skips actionlint when the pinned version is already present, so repeat runs stay cheap.

### Changed

- README.md documents the new toolchain, adds `github.com` to the list of hosts the installer needs to reach, and notes that re-runs update the toolchain in place. The "Testing changes" section now asks for a shellcheck run in addition to the existing `bash -n` syntax check, on the grounds that the installer provides shellcheck itself. That section also explains that the toolchain lives inside the heredoc that runs in the container, which shellcheck does not see when it reads the outer file, and gives the awk command that extracts the inner script so it can be checked separately.
- CHANGELOG.md was converted from the previous round-based numbered format to Keep a Changelog 1.1.0. The old header pointed readers at `CHANGELOG_TEMPLATE.md` in Kinsman4249/.github-private, a file that repository has since deleted, so the reference no longer resolved. The two existing rounds of work were remapped onto the `v1.0.0` and `v1.1.0` tags that already existed, dated from those tags, with entries sorted into Added and Fixed subsections. No entry text was dropped in the conversion.

## [1.1.0] - 2026-08-05

### Added

- The installer now symlinks `distrobox` to `distrobox-host-exec` at `/usr/local/bin/distrobox` inside the `vscodium-box` container, so `distrobox` commands typed into VSCodium's integrated terminal forward to the real host distrobox instead of silently doing nothing (the container itself has no podman/docker of its own to talk to). The symlink is only created if nothing already occupies that path, or if it's a symlink this script created before, so a real `distrobox` binary a user installed manually is never clobbered. README.md documents the mechanism under a new "Running distrobox from VSCodium's terminal" section.

- Expanded README.md with a "Why not Homebrew or Flatpak?" section explaining the project's rationale against the two other common no-touch-the-base-OS install paths: Homebrew's `vscodium` cask is macOS-only, with Linux users pointed at unofficial source-build taps with no binary or signature from the VSCodium project; Flatpak's official Flathub build sandboxes VSCodium away from host toolchains, requiring a separate Flatpak SDK extension per language with only partial coverage. This project's unsandboxed Debian container gets the real upstream `.deb` plus unrestricted access to whatever toolchains are installed in the container or reachable via `distrobox` commands.

### Fixed

- Fixed the exported launcher's icon not showing up in the taskbar/dock (only in the app grid/start menu). The icon is now installed into the host's hicolor icon theme (`~/.local/share/icons/hicolor/512x512/apps/vscodium.png`) and referenced by name (`Icon=vscodium`) rather than by absolute path - taskbars and docks resolve a running window's icon by looking up its `.desktop` file's `Icon=` name through the icon theme, and an absolute path doesn't resolve there even though it works fine for the app-grid entry. The old absolute-path icon copy from a previous version is removed on update.

## [1.0.0] - 2026-08-05

### Added

- Added install-vscodium.sh, a one-click installer/updater that creates a Debian 12 Distrobox container named vscodium-box, installs VSCodium from its official apt repository (download.vscodium.com) with a signed-by-pinned signing key following the instructions published at vscodium.com, and exports the app to the host's application launcher via distrobox-export. The script is idempotent - re-running it updates VSCodium in place - and supports --remove to tear down the container and exported app cleanly, plus --debug for a full command trace. It is modeled on the sibling claude-desktop-for-immutable installer but deliberately ships none of that project's Cowork/QEMU/vhost_vsock virtualization tooling, since VSCodium does not need it.

- The installer also provisions git and the GitHub CLI (gh) inside the same container, so VSCodium's built-in source control and any integrated-terminal or agent workflows have them available. git comes from Debian's own repositories; gh is installed from GitHub's official apt repository (cli.github.com) with its own signed-by-pinned keyring, because Debian 12 does not carry gh in its standard repositories.

- Added a patch_launcher_flags step, run after every distrobox-export, that inserts --disable-gpu-compositing into the exported launcher's Exec= line. This works around the same Electron GPU-process repaint bug the sibling project hit on hybrid Intel+NVIDIA hardware, where text renders garbled or ghosted; disabling only GPU compositing (rather than all acceleration) clears it. The sed is written to match only the codium command after distrobox-enter's "--" separator, never the "-n vscodium-box" container name, which also contains the substring "codium". README.md documents how to remove the flag if a given machine doesn't need it. The same step also fixes the launcher icon: distrobox-export falls back to the generic Debian icon because VSCodium's icon lives in the container's /usr/share/pixmaps (which, unlike $HOME, isn't shared with the host), so patch_launcher_flags copies /usr/share/pixmaps/vscodium.png out of the container onto the host and rewrites every Icon= line to that absolute path. Both behaviors were verified end-to-end against a live install (VSCodium 1.126.04524): the flag lands once on each of the two Exec= lines and never on the container name, and the copied icon is a valid 1024x1024 PNG.

- Added project scaffolding adapted from the Kinsman4249/.github-private templates: README.md describing the purpose, mechanism, prerequisites, usage, and GPU note; community health files (CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md); .github/ issue and pull-request templates; a release.yml workflow that bundles tagged commits into .tar.gz/.zip archives on vX.Y.Z tag pushes; a .gitignore that skips session files (handoff.md, todo.md, .claude/); and this CHANGELOG.md.
