# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [5.0.0] - 2026-08-15

### Changed

- README.md now points to runpod-helper's own `startup.sh` (which offers to run the sync automatically after every launch) instead of documenting `sync-runpod-endpoint.sh` directly, while keeping this repo's explanation of why the sync works at all: `~/.config/kilo/` and `~/.config/opencode/` inside vscodium-box are a straight bind mount of a host directory, not really "inside" the container, letting an external script edit those files without `podman exec` or a running container.
- "Testing changes" in README.md now lists three scripts (`install-vscodium.sh`, `uninstall-vscodium.sh`, `provision-container.sh`) instead of four, matching the removal below.
- .gitignore now also excludes `.kilo/kilo.jsonc`.

### Removed

- `sync-runpod-endpoint.sh`, moved to the [runpod-helper](https://github.com/Kinsman4249/runpod-helper) repo, where its `startup.sh` now offers to run the equivalent sync automatically after every launch.

## [4.1.0] - 2026-08-15

### Added

- `provision-container.sh` now installs `libsecret-tools` (provides `secret-tool`), the last missing package prerequisite for `runpod-helper`'s `startup.sh`, which stores `RUNPOD_API_KEY` in the OS keyring via that binary. Everything else `runpod-helper` needs - `bash`, `ssh`, `curl`, `openssl`, `git`, `runpodctl` - was already present in the box. `secret-tool` still needs a reachable D-Bus session bus with an unlocked Secret Service to actually work at runtime, which apt can't provide; see `runpod-helper/PREREQUISITES.md`.
- `install-vscodium.sh` now writes a second launcher/`.desktop` pair - `~/.local/bin/vscodium-box-console` and `vscodium-box Console` in the app grid - that runs `podman exec` straight into a login shell in the container instead of starting VSCodium. It shares the same env-forwarding logic as the VSCodium launcher (factored out into a new `compute_env_args` helper so both stay in sync with however the container was actually created) and uses `Terminal=true` in the `.desktop` entry so the desktop environment supplies whatever terminal emulator the user already has set as default, rather than this script hardcoding one. `uninstall-vscodium.sh` removes both new files alongside the existing ones.
- New `sync-runpod-endpoint.sh` writes a `runpod-helper` `startup.sh` launch's `baseURL`/`apiKey`/model name into Kilo Code's `~/.config/kilo/kilo.jsonc` and opencode's `~/.config/opencode/opencode.jsonc` inside vscodium-box, since runpod-helper generates a fresh proxy URL and one-off API key on every launch with nothing stored, and a stale endpoint in either file was confirmed live (via a real pod launch) to cause escalating tool-call/path corruption in Kilo's output rather than a clear connection error - opencode's config had gone stale in exactly the same way, pointing at the same torn-down pod. It edits the host copy of the container's private home directly - no `podman exec` or running container needed, since that directory is a straight bind mount - and only touches the fields it knows about via `jq`, leaving hand-edited ones (extra models, Kilo's `permission` block) alone. Only Kilo Code and opencode are covered; Cline and Roo weren't found installed in this container. Defaults to vscodium-box's private home; `--container-home DIR` points it at any other container built the same way instead.
- `provision-container.sh` now adds `~/.opencode/bin` to `PATH` via `/etc/bash.bashrc`, since opencode installs itself there but does not put itself on `PATH` on its own.

### Fixed

- `provision-container.sh` now installs Node.js 24.x from NodeSource's signed apt repository instead of Debian 12's own package (18.19). DeepSeek Harness was completely broken as a result - every `dsh` invocation crashed with `SyntaxError: The requested module 'node:util' does not provide an export named 'parseEnv'`, confirmed live. `util.parseEnv` was added to Node.js in v24.0.0 ([Node.js docs](https://nodejs.org/api/util.html#utilparseenvcontent)), matching dsh's own `package.json` engines field (`^22.19.0 || >=24.0.0`), so 24.x is the actual floor either way. Signing key and repo layout follow the [manual installation method](https://github.com/nodesource/distributions/wiki/Repository-Manual-Installation) NodeSource documents, pinned the same way VSCodium/gh/Claude Code already are in this script.
- `provision-container.sh` now `chown`s `~/.npm` back to the box user after installing/updating DeepSeek Harness. `$HOME` inside the container resolves to the box user's private home even when this script runs as root (it's the container's own env default, not root's `/root` - see `HOME=` in `install-vscodium.sh`'s `podman create`), so every `npm install -g` during provisioning was leaving cache/log files there owned by root - 6000+ files, confirmed live - which then `EACCES`d the next `npm install` the box user ran themselves.
- `provision-container.sh`'s container-user setup now handles rootless podman's `--userns=keep-id`, which auto-injects a passwd entry for the host UID (built from the host account, but with shell forced to `/bin/sh` and no real home) before provisioning ever runs - so the script's existing `useradd` branch was always skipped and that broken entry was left in place untouched. It now detects the pre-existing entry and fixes it up with `usermod` (renaming it to `$BOX_USER` if needed, then setting `--home "$BOX_HOME" --shell /bin/bash`) instead of silently no-oping.

## [4.0.1] - 2026-08-15

### Fixed

- `provision-container.sh` now appends `LANG=C.UTF-8` and `LC_ALL=C.UTF-8` to `/etc/bash.bashrc` inside the container, if not already present. Debian's minimal image leaves both unset, which falls back to the POSIX/C locale and breaks tools that assume a Unicode-aware locale - for example, a `grep -P` matching emoji by codepoint range errored out under it instead of just finding no matches. glibc has shipped the `C.UTF-8` locale built in since 2.35, so no `locales` package or `locale-gen` is needed. This is a shell default rather than a container-level `podman create --env` because the thing that needs it - VSCodium's integrated terminal and anything launched from it - runs as a non-login interactive shell, and Debian's bash always sources `/etc/bash.bashrc` for those regardless of the container-creation-time environment.

## [4.0.0] - 2026-08-15

### Added

- `provision-container.sh` now installs Node.js and npm from Debian's own repo (no extra signing key needed, same as Chromium), then installs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) from npm as the default agent harness. It is an MIT-licensed developer preview, first released 2026-08-13, with no signing key of its own to pin - npm's registry integrity checks are the only verification available. Run `dsh web` in VSCodium's terminal and log in on first use.
- `install-vscodium.sh` gained a `--claude` flag to opt back into installing Claude Code.

### Changed

- Claude Code is no longer installed by default. `provision-container.sh` only sets up its signing key, apt repository, and package install when `BOX_WITH_CLAUDE=1`, which `install-vscodium.sh` sets from the new `--claude` flag. Unlike `--repos-dir`, this flag is not remembered between runs - pass it again on every run where Claude Code should be installed or updated. Existing installs that relied on a plain re-run to keep Claude Code current now need `--claude` on that re-run.
- README.md was updated throughout to reflect DeepSeek Harness as the default agent harness and Claude Code as opt-in: the feature list, the mount table, the numbered installer-steps list, the signing-key-trust section, the prerequisites/network-access list, the usage examples, and the testing checklist.

## [3.2.0] - 2026-08-13

### Added

- `provision-container.sh` now installs **runpodctl** from the upstream release binary, v2.9.0, pinned by SHA-256 checksum per architecture. The binary is placed in `/usr/local/bin` and is available inside the container for interaction with Runpod's cloud API and pod management.

## [3.1.0] - 2026-08-13

### Added

- `provision-container.sh` now installs **Chromium** from Debian's own repo (no extra signing key needed, unlike VSCodium/gh/Claude Code). It's a plain browser so sites that gate login behind a WebAuthn/passkey prompt handled in-browser JS can be used from inside the container. It does not wire up a physical security key (YubiKey/FIDO2 USB) - that would need `/dev/hidraw` or `/dev/bus/usb` passed into the container, which `install-vscodium.sh` does not do.

## [3.0.0] - 2026-08-13

### Added

- `install-vscodium.sh` gained two new opt-out flags to go with the new defaults below: `--wayland`, which switches the display mount back to the native Wayland socket instead of XWayland, and `--no-gpu`, which forces `--disable-gpu` even when `/dev/dri` is present. Both are creation-time-only, same as the flags they sit alongside.
- Uninstalling is now a separate `uninstall-vscodium.sh` script instead of `install-vscodium.sh --remove`. It does exactly what `--remove` used to: delete the `vscodium-box` container, the host launcher and `.desktop` entry, and known leftovers from the pre-podman Distrobox setup (its exported `.desktop` file and icon), while leaving the repos directory, the container's private home, and the saved `--repos-dir` config untouched. `install-vscodium.sh` points to it in its own `--help` output and in the message it prints when it finds a container that needs recreating.

### Changed

- `install-vscodium.sh` now defaults to XWayland plus GPU passthrough (`USE_X11=1`, `USE_GPU=1`) instead of native Wayland with software rendering. The reason is a reproducible crash: on the host this was tested against (KWin 6.7.3 / Plasma 6), VSCodium's bundled Electron binds `zwp_linux_dmabuf_v1` version 4 while KWin offers version 5, and Electron's handling of that protocol's `format_table` event segfaults within about a minute of the window opening, with or without GPU compositing disabled. XWayland uses the older, stable X11 Ozone backend and does not hit that path, so it is now what a plain `./install-vscodium.sh` gives you. GPU passthrough follows the same "make the common case work" reasoning: `/dev/dri` is now passed through automatically when it exists, with a silent fall-back to software rendering (no `die`) when it does not, rather than requiring an explicit `--gpu` flag as before. The old `--gpu` and `--x11` flags still parse and are still accepted - they are just no-ops now, kept only so that existing muscle memory and scripts referencing them do not break.
- README.md was refactored to match: the "What the container can and cannot reach" table now lists `/dev/dri` and the X11 socket as on by default and the Wayland socket as opt-in via `--wayland`; a new "Wayland note" section documents the `zwp_linux_dmabuf_v1` crash in full and gives the `ausearch`/`audit2allow` recipe for the separate SELinux `connectto` policy module that native Wayland needs beyond the mount-level `z` relabel; and the "GPU note" section was rewritten since `--disable-gpu-compositing` is now applied unconditionally (it fixes a GPU-process repaint bug, not GPU access) while `--disable-gpu` itself is now conditional on GPU passthrough being off.

### Removed

- The `--remove` flag was removed from `install-vscodium.sh`; the `ACTION="remove"` branch and its `do_remove()` implementation are gone. Anything still invoking `install-vscodium.sh --remove` - a saved alias, a script, muscle memory - now gets `Error: Unknown option: --remove` instead of a teardown. Use `./uninstall-vscodium.sh` instead, per the Added entry above.

### Fixed

- The X11 socket, the `XAUTHORITY` file, and the Wayland socket bind mounts in `create_container()` now all carry the `,z` SELinux relabel option; previously only the two writable mounts (repos dir, container home) got it, and the display sockets were mounted read-only without a relabel. That gap matters now that XWayland is the default path: without `z` on `/tmp/.X11-unix/X$N` and `$XAUTHORITY`, `container_t` cannot read them under enforcing SELinux, and VSCodium would exit with no window and no visible error outside `--debug`, the same failure mode already noted for the Wayland socket in the prior release.

## [2.0.0] - 2026-08-12

### Changed

- The installer no longer uses Distrobox. It now creates and drives the `vscodium-box` container with rootless podman directly, because Distrobox cannot give the container scoped access to the host filesystem, which is what this change set out to achieve. An earlier attempt used `distrobox create --home` plus a `--volume` of a single `--repos-dir` and claimed the container could see nothing else in the home directory. That claim was false. Distrobox bind-mounts the host `$HOME` at its real path unconditionally, before and independently of any custom home, and its own documentation says the `--home` flag "will NOT prevent the mount of the host's home directory, but will ensure that configs and dotfiles will not litter it". It also mounts all of `/` at `/run/host`, read-write for every writable top-level directory, and no `--unshare-*` flag removes that, while the container itself runs `--privileged` with SELinux and AppArmor confinement disabled and the host's `/tmp`, PID, IPC and network namespaces shared. Those are reasonable defaults for the problem Distrobox solves and the wrong ones for running an editor, a coding agent, and third-party extensions.
- The container is now created with exactly three bind mounts and nothing else: the directory passed to `--repos-dir` read-write, the container's own private home under `~/.local/state/vscodium-box/home` read-write, and the Wayland socket read-only. It is not privileged, it gets no `/dev` or `/sys`, no `/run/host`, no host `/tmp`, no D-Bus session socket, and podman's default private PID, IPC and network namespaces. SELinux confinement stays on, with the two writable mounts relabeled using the shared `z` option so host tools keep working on the same files. `--userns keep-id` keeps ownership of files written into the repos directory correct on the host side, and the private home is mounted at the host home's path so `~` and absolute paths still behave normally inside.
- What is given up in exchange is documented rather than quietly dropped. The `distrobox` to `distrobox-host-exec` symlink is gone, which removes a direct escape hatch from the container to the host. Without a D-Bus session socket there are no portals, so clicking a link no longer opens the host browser and `gh` stores its token in its own config file instead of a secret service. Rendering is done in software unless the new `--gpu` flag is passed to expose `/dev/dri`, and a dev server started inside the container is not reachable from the host unless the new `--publish PORT` flag was passed at creation time, which publishes on `127.0.0.1` only. A new `--x11` flag mounts a single XWayland socket read-only for the case where Electron will not start on Wayland. The installer must now be run from a host terminal rather than VSCodium's own, and it says so plainly if it detects that it is running inside a container.
- The inner provisioning script moved out of the heredoc and into its own file, `provision-container.sh`, which is piped into the container with `podman exec -i --user root ... bash -s`. Nothing is written to disk, so the previous temporary file in the container's home, and the window in which a process inside the container could have rewritten it between the write and the exec, are both gone. As a side benefit shellcheck now reads that half of the project directly, and the awk extraction command the README used to document is no longer needed.
- The launcher is generated rather than patched. `distrobox-export` and the `sed` that edited its output are replaced by a wrapper script at `~/.local/bin/vscodium-box` and a `.desktop` entry written from a template in the installer. Both live on the host in paths the container cannot reach, so a process inside it can no longer rewrite the entry the user clicks on. The icon is still installed into the host's hicolor theme by name, for the same reason as before: taskbars resolve a window's `StartupWMClass` to a desktop file and then look up its icon *name*, which an absolute path does not satisfy.
- `--repos-dir` is now validated instead of merely being resolved to an absolute path. It must be an existing directory under the home directory, and `/`, `/home`, `/var/home`, `/etc`, `/usr`, `/var`, `/tmp` and the home directory itself are refused, as are paths containing `:` or `,`, which are field separators in a podman `--volume` argument. The path is canonicalised with `realpath`, so neither a symlink nor `..` can be used to dodge those checks. The saved value in `~/.config/vscodium-box/repos-dir` is treated as untrusted input when it is read back: the file is rejected if it is a symlink, is not owned by the current user, or is group- or world-writable, only its first line is used, and it goes through the same validation as a value passed on the command line.
- Installing over an existing Distrobox `vscodium-box` is refused rather than attempted. The installer detects the container by its `manager=distrobox` label and prints the exact commands to remove it, including the old exported desktop entry, along with a warning that the old container's settings and extensions go away with it.

### Fixed

- The signing keys for the VSCodium and GitHub CLI repositories are now verified by fingerprint before they are trusted, the same way the Claude Code key already was, and all three go through one shared helper. The helper checks that *every* primary key in the downloaded file is one the script expects, rather than merely that the expected key is present somewhere in it, so an extra key cannot be smuggled into a file that still carries the legitimate one. The comment claiming that GitHub publishes no fingerprint was wrong: two are published at the top of `docs/install_linux.md`, along with checksums of the keyring file. The fingerprints are pinned rather than that checksum, because the file carries two keys and the older one expires in early 2027, so the file itself will be replaced. VSCodium genuinely publishes no fingerprint, and its key is fetched from the same URL the install instructions point at, so the comment in the script now says outright that the pin there is change detection and not an independent trust anchor.

## [1.3.0] - 2026-08-08

### Added

- The installer now provisions Claude Code inside `vscodium-box`, alongside VSCodium, git, gh, and the lint toolchain. It is installed from the signed apt repository on the `stable` channel rather than through the `curl https://claude.ai/install.sh | bash` one-liner the upstream documentation leads with. A package manager install is the better fit for this project: it is pinned to a signing key like every other repository the script adds, it upgrades along with everything else when the script is re-run, and it keeps the binary out of `~/.local/bin`, which is bind-mounted from the host and would otherwise place a container-built binary on the host's own PATH. That is the same reasoning already applied to the `fd` and `distrobox` shims. Unlike the VSCodium and GitHub CLI repositories, upstream publishes the key's fingerprint, so the script verifies it with `gpg --show-keys --with-colons` before trusting the key instead of relying on the HTTPS download alone. The machine-readable form is used deliberately, because the human-readable output is spaced in groups of four and would have to be normalized before it could be compared.
- Failure handling for the new step is deliberately narrow, so that a bad day at the download host cannot take the rest of the environment down with it. A key that fails to download, or one whose fingerprint does not match, prints a warning, skips Claude Code, and leaves everything else untouched. The repository is only registered once the key has actually passed that gate, because a source list whose `signed-by` keyring is missing makes every subsequent `apt-get update` fail. The package itself is installed in its own `apt-get install` call rather than being appended to the existing one, so a failure there cannot prevent VSCodium from being installed or updated.
- The build stamp moved to `2026.08.08-1`, and `README.md` now documents the new step, the reason the signed repository was chosen over the install script, and the fact that an apt install of Claude Code does not update itself, so re-running the installer is how it moves forward. The testing section now expects `claude` on PATH in the integrated terminal, verified with `claude --version`.

## [1.2.1] - 2026-08-06

### Changed

- README.md now describes the project as a development environment provisioner rather than an editor installer, which is what it became once it started installing git, gh, and the lint toolchain alongside VSCodium. The opening section states that the environment is defined by this one script, so it is reproducible and survives a container rebuild, and that new tools should be added here rather than installed by hand into the container. The repository description and topics on GitHub were updated to match.

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
