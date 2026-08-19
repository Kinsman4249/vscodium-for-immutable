# vscodium-for-immutable

One script that provisions a working development environment on immutable
Fedora hosts (Bazzite, Silverblue, Kinoite, and similar), where you can't
install `.deb`/`.rpm` packages onto the base OS.

It installs **VSCodium** from its official `.deb` package into a rootless
**podman** container, along with the tools you actually need next to an editor:
**git**, the **GitHub CLI**, **DeepSeek Harness**, **Chromium**, and a lint
toolchain (**shellcheck**, **actionlint**, **jq**, **fd**, **yamllint**).
On a host with an NVIDIA GPU and the NVIDIA Container Toolkit it also hands the
whole GPU to the container (CDI) and provisions the **CUDA toolkit** plus the
LLM runtimes **vLLM**, **Ollama**, and **llama.cpp** inside it, so a model can
run fully on the GPU. **Claude Code** is available too, opt-in via `--claude`.
A pinned **watermarks-remover** service (python stdlib) is installed as well - the
`remove-ai-marks` skill scrubs against it via `curl`, with the service started
inside the box on demand by `watermarks-serve`. The same-scheme watermark
harness backends (**MarkLLM** and **reverse-SynthID**) are installed by default
too, for controlled before/after verification of prose and images - opt out with
`--no-wm-harnesses` (see
[Watermark harness backends](#watermark-harness-backends)). The script then
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
| the NVIDIA GPU (`nvidia.com/gpu`) | read-write via CDI | the whole GPU for CUDA - the LLM runtimes (vLLM/Ollama/llama.cpp) | yes, if present (`--device nvidia.com/gpu=all`; pass `--no-cuda` to opt out) |
| the Wayland socket | read-only | native Wayland instead of XWayland | no (pass `--wayland`; see [Wayland note](#wayland-note)) |
| a `--publish` port | host `127.0.0.1` only | reach a dev server started inside the box | no |

The private home is mounted at the same path as your host home, so `~` and
absolute paths behave normally inside the container - but its contents are that
state directory, not your home.

**Never** mounted or shared, with no flag that changes it: your host home, the
host filesystem (no `/run/host`), host `/tmp`, any device other than
`/dev/dri` and the NVIDIA GPU device nodes, the host D-Bus session, the host
PID and IPC namespaces, or the host network namespace (a `--publish` port is
forwarded in, not a shared namespace). The container also never runs
`--privileged` and is never given `--security-opt label=disable`, so SELinux
confinement (mounts are relabeled with `z`) stays enforced against it exactly
as it would against any other process on the host. The NVIDIA passthrough is
CDI-driven - it adds only the `/dev/nvidia*` nodes and the driver libraries
(`libcuda`, NVML, `nvidia-smi`), never `--privileged`, and the one targeted
SELinux allow rule it needs is a separate, documented host change (see the
[CUDA note](#cuda-note)).

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
7. Installs **Node.js 24.x** from NodeSource's signed apt repository (Debian
   12's own repo only carries 18.19, three majors short of what DeepSeek
   Harness actually needs - see [Signing key trust](#signing-key-trust)),
   then installs **DeepSeek Harness** (`@deepseek-ai/dsh`) from npm - it's
   Node-based and has no apt/dnf/apk repo of its own. This is the default
   agent harness; still a developer preview, so expect breaking changes
   upstream. Run `dsh web` in VSCodium's terminal and log in on first use.
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
11. Writes a third launcher/`.desktop` pair -
    `~/.local/bin/vscodium-box-restart` and `vscodium-box Restart` in your app
    grid - that restarts the container. See [Fixing Permission denied inside
    the box](#fixing-permission-denied-inside-the-box) for what it is for.
12. Adds `--disable-gpu-compositing` to the launcher's command line
    unconditionally, and `--disable-gpu` too if `/dev/dri` isn't available (or
    `--no-gpu` was passed). See [GPU note](#gpu-note) below.
13. Installs VSCodium's icon into the host's `hicolor` icon theme
    (`~/.local/share/icons/hicolor/512x512/apps/vscodium.png`) and points the
    launcher's `Icon=` at it by name, so it shows up correctly in both the
    app grid/start menu and the taskbar/dock (an earlier version pointed
    `Icon=` at an absolute file path, which most taskbars can't resolve).
14. When the host has `/dev/nvidiactl` and the NVIDIA Container Toolkit's CDI
    spec, passes the whole GPU to the container with `--device
    nvidia.com/gpu=all` (off by default only when `--no-cuda` was passed or
    there's no driver) and installs the one targeted SELinux allow rule it
    needs (best-effort via `sudo`; see the [CUDA note](#cuda-note)).
15. When the GPU was passed and `--no-llm` wasn't, provisions the CUDA stack
    inside the container: the **CUDA toolkit** (nvcc/cuBLAS, from NVIDIA's
    signed Debian repo), **Ollama** (pinned upstream binary), a CUDA build of
    **llama.cpp** (`llama-cli`/`llama-server`), and a **vLLM**-ready Python
    venv with CUDA torch (`~/llm-venv`). See the [CUDA note](#cuda-note).
    On a GPU-less host these steps are skipped entirely.

### Watermark harness backends

The `watermarks-remover` service can verify watermarks, but only honestly, as a
same-scheme harness, not a vendor detector. To do that it needs two optional
backends, both installed by default (opt out with `--no-wm-harnesses`, or keep
them off by phrasing it as a re-run after a `--no-wm-harnesses` install):

- **MarkLLM** ([THU-BPM/MarkLLM](https://github.com/THU-BPM/MarkLLM)): a
  controlled, same-scheme prose harness. With it, the service can
  watermark+detect text under a scheme you choose (e.g. KGW), so a before/after
  diff shows whether text that cleared `remove-ai-marks`' Layer A also clears
  that same scheme. It does **not** certify vendor schemes: there is no public
  DeepSeek watermark scheme, so nothing here can prove text is not DeepSeek
  watermarked.
- **reverse-SynthID** ([aloshdenny/reverse-SynthID](https://github.com/aloshdenny/reverse-SynthID)):
  pixel-domain only, scores images (SynthID). It is not exercised by prose
  rewrite flows.

The backends live in the box's private home and are exposed to the service at
startup:
`MARKLLM_DIR=$HOME/MarkLLM` and `REVERSE_SYNTHID_DIR=$HOME/reverse-SynthID`.
To verify inside the box (for example, from VSCodium's integrated terminal):

```bash
# prose: watermark + detect under the KGW scheme (first detect downloads opt-1.3b)
"$HOME/MarkLLM/.venv/bin/python" \
  /usr/local/lib/watermarks-remover/detect_text_watermark.py watermark sample.txt \
  --scheme kgw -o wm.txt -o2 plain.txt
"$HOME/MarkLLM/.venv/bin/python" \
  /usr/local/lib/watermarks-remover/detect_text_watermark.py detect wm.txt --scheme kgw --json

# images: emit a SynthID score for a PNG
"$HOME/reverse-SynthID/.venv/bin/python" \
  /usr/local/lib/watermarks-remover/score_synthid.py sample.png
```

Because both harnesses are only downloaded on demand (torch for MarkLLM, the
spectral codebook for reverse-SynthID), a fresh install is slow once and cheap
on re-runs. Files on the first install are written by root during provisioning;
they are chowned back to the box user automatically, so the venv pythons above
run without `sudo`.

The venvs are built on a standalone CPython 3.12 that the provisioner installs
from
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(pinned tag + SHA-256, verified before extract, into
`/usr/local/lib/python-build-standalone/`). The vendored MarkLLM /
reverse-SynthID requirements target Python >=3.12 (they pin 3.12-only
`numpy==2.5.2` and `scipy==1.18.0`), which Debian 12's system `python3` (3.11)
cannot satisfy; shipping this standalone 3.12 keeps every upstream pin intact.
On a re-run the provisioner skips the download once the interpreter is present.

### Signing key trust

All four apt repositories are pinned to a dedicated keyring with `signed-by`,
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
- **NodeSource** (Node.js): same story as VSCodium - no published fingerprint,
  so this pin is change detection only, not an independent trust anchor.
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
  `deb.nodesource.com` (Node.js), `registry.npmjs.org` (DeepSeek Harness),
  `github.com` (actionlint, runpodctl, Ollama, llama.cpp release assets), and
  Debian's mirrors, and, if you pass `--claude`, `downloads.claude.ai`. The
  CUDA LLM runtimes additionally need `download.pytorch.org` (torch) and
  `developer.download.nvidia.com` (the CUDA toolkit and its keyring).

### NVIDIA GPU (optional, for the CUDA LLM runtimes)

To run a model on the GPU, the host needs two things, both already present on
the box this was built for:

- The **NVIDIA driver** (kernel module + `/dev/nvidia*` nodes). The container
  gets the driver from the host via the Container Toolkit - nothing is
  installed inside the box.
- The **NVIDIA Container Toolkit** (`nvidia-container-toolkit`) with a CDI
  spec generated, so podman can expose `nvidia.com/gpu`:

  ```bash
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  ```

  The installer treats a present `/dev/nvidiactl` **and** `/etc/cdi/nvidia.yaml`
  as "this host can hand over the GPU". If only the driver is there (no spec),
  `--cuda` at create time errors out rather than silently doing nothing.

CUDA is **on by default** when the driver + CDI spec are present; pass
`--no-cuda` to keep the GPU out, or `--no-llm` to still hand it over but skip
the multi-gigabyte CUDA toolkit and LLM runtime installs.

## Usage

Run these from a **host** terminal:

```bash
./install-vscodium.sh --repos-dir ~/github   # install, scoped to that directory
./install-vscodium.sh                        # update, reusing the saved repos dir
./install-vscodium.sh --wayland              # use native Wayland instead of XWayland
./install-vscodium.sh --no-gpu               # force software rendering
./install-vscodium.sh --no-cuda              # do not expose/pass the NVIDIA GPU
./install-vscodium.sh --no-llm               # skip the CUDA LLM runtimes + toolkit
./install-vscodium.sh --publish 3000         # publish a port on 127.0.0.1
./install-vscodium.sh --claude               # also install Claude Code
./install-vscodium.sh --no-wm-harnesses      # skip MarkLLM / reverse-SynthID backends
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
would defeat the point. `--repos-dir`, `--wayland`, `--no-gpu`/`--gpu`,
`--no-cuda`/`--cuda`, `--no-llm` and `--publish` are fixed when the container
is created; changing them means `./uninstall-vscodium.sh` followed by a fresh
install. (`--gpu`, `--x11` and `--cuda` are still accepted - they're just the
defaults now, kept as no-ops so old habits and scripts don't break.)

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

## CUDA note

This is for running a model **on the GPU**, separate from the `/dev/dri`
rendering path above. When the host has an NVIDIA driver and the NVIDIA
Container Toolkit's CDI spec, the installer exposes the whole GPU to the box
and provisions the CUDA stack inside it:

- **GPU passthrough** - `podman create --device nvidia.com/gpu=all`. Every
  `/dev/nvidia*` node, NVML, and the driver libraries (`libcuda`, `nvidia-smi`)
  come from the host via the CDI hook; the box never installs a driver, and
  this needs no `--privileged` and no `--security-opt label=disable`.
- **CUDA toolkit** - nvcc + cuBLAS + the CUDA runtime, from NVIDIA's signed
  Debian 12 apt repo. Needed to *compile* llama.cpp with CUDA (upstream ships
  no CUDA-enabled Linux prebuilt - its linux-x64 tarball is CPU-only) and to
  give the box a real toolkit.
- **Three LLM runtimes**, each best-fit to how it gets CUDA:
  - **vLLM** - `pip install vllm` (with torch pulled first from PyTorch's
    CUDA 12.8 index) into `~/llm-venv`. vLLM and torch bundle their own CUDA
    runtime and just use the injected driver.
  - **Ollama** - the self-contained upstream binary (bundles CUDA), pinned
    with an explicit SHA-256. Models land under `~/.ollama/models`.
  - **llama.cpp** - built from a pinned source tag with `-DGGML_CUDA=ON`,
    installing `llama-cli` and `llama-server` (cuBLAS-accelerated).

To verify the whole pipeline from inside the box (a `vscodium-box Console` or
VSCodium's integrated terminal):

```bash
nvidia-smi
# GPU 0: NVIDIA GeForce RTX 3080 Laptop GPU (...)
"$HOME/llm-venv/bin/python" -c 'import torch; print(torch.cuda.is_available())'
# True
```

### The one SELinux rule it needs

`/dev/nvidia*` is labeled `xserver_misc_device_t` by systemd-udev, and the
container's process domain (`container_t`) is denied that type (it's allowed
`dri_device_t` - that's why `/dev/dri` rendering works with no extra rule). So
without a targeted allow rule, CUDA inside the box fails with
`Failed to initialize NVML: Insufficient Permissions` even though every device
node is present. Exactly like the Wayland rule above, this is a standing,
host-level policy change - it is not scoped to one container and is not undone
by `./uninstall-vscodium.sh`.

The installer ships the rule as `selinux/vscodium-box-nvidia.te` and tries to
compile + install it at create time via `sudo -n` (best-effort, never hangs).
If sudo needs a password here - it does on this box - do it by hand once:

```bash
sudo checkmodule -M -m -o /tmp/vscodium-box-nvidia.mod \
  /path/to/vscodium-for-immutable/selinux/vscodium-box-nvidia.te
sudo semodule_package -o /tmp/vscodium-box-nvidia.pp -m /tmp/vscodium-box-nvidia.mod
sudo semodule -i /tmp/vscodium-box-nvidia.pp
```

Remove it with `sudo semodule -r vscodium-box-nvidia` if you stop using the GPU.
Without it the box simply can't open the GPU - everything else still installs.

The GPU passthrough and CUDA provisioning are fixed at container creation
(`--no-cuda`/`--no-llm` change them only on a fresh install), and the CUDA
runtimes no-op on hosts with no driver, so a plain `./install-vscodium.sh` on a
GPU-less machine is unchanged.

## Fixing Permission denied inside the box

The bind mounts are marked `,z`, which makes podman relabel mounted files for
SELinux - from `user_home_t` on the host to `container_file_t` the container
can read. That relabel runs at **mount time**, not at file-in-place time. So a
file you create on the host *after* the container was started (a repo you
`git clone`, a file you drag into the mounted folder) keeps its host label,
and the container process (`container_t`) is denied reading or even `stat`-ing
it until the container is restarted and podman relabels the mount again.

That is what you're hitting when the box says `Permission denied` on a file you
just dropped into a mounted folder: the file *is* there, its SELinux label just
says it isn't for the container.

The **vscodium-box Restart** app-grid entry exists for exactly this: it stops
and starts the container, re-running the `,z` relabel so host-created files
become readable inside. The container runs `sleep infinity`, so this is quick
and only re-relabels - it does not reinstall anything. The trade-off is that it
also terminates the running VSCodium (and any shell session in the box), which
is why it is an explicit app-grid action rather than something the editor
triggers on its own.

## Syncing a runpod-helper pod into Kilo Code and opencode

If you use [runpod-helper](https://github.com/Kinsman4249/runpod-helper) to
run a self-hosted model and talk to it from Kilo Code or opencode inside
vscodium-box, its `startup.sh` now asks after every launch whether to push
the fresh `baseURL`/`apiKey`/model straight into both tools' configs -
`sync-runpod-endpoint.sh`, which lives in that repo (see its README's
"Syncing into vscodium-box" section), not here.

What makes that possible is this project's own layout: `~/.config/kilo/` and
`~/.config/opencode/` inside vscodium-box are not really inside the
container at all. They live under vscodium-box's private home on the host
(`~/.local/state/vscodium-box/home/.config/...`), which is a straight bind
mount - see [What the container can and cannot reach](#what-the-container-can-and-cannot-reach).
Editing the host copy edits the container's copy directly, no `podman exec`
or running container needed, which is exactly what lets a script in another
repo update those configs on its own.

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

If you're on a host with an NVIDIA GPU, verify the passthrough end-to-end. The
container mounts no `/dev/nvidia*` unless the SELinux module in the
[CUDA note](#cuda-note) is installed, so without it `podman exec` sees the
devices but `nvidia-smi` inside fails with `Insufficient Permissions`:

```bash
podman exec vscodium-box nvidia-smi          # must list your GPU
podman exec vscodium-box /bin/bash -lc '"$HOME/llm-venv/bin/python" -c "import torch; print(torch.cuda.is_available())"'  # True
podman inspect vscodium-box --format '{{range .Devices}}{{.Path}}{{"\n"}}{{end}}'  # the /dev/nvidia* nodes
```

Finally, launch VSCodium from the app grid and check that the icon appears in
the taskbar and that its integrated terminal has `git`, `gh`, `actionlint`,
`fd`, and `dsh` (check with `dsh --version`) - and, if you passed `--claude`,
`claude` (`claude --version`) too. Launch "vscodium-box Console" from the app
grid too and check that it opens a bare shell in the same container (`echo
$HOME` should print the container's real home path, not start VSCodium). Then
create a new file on the host inside the mounted folder while the box is
running and check it reads `Permission denied` from inside, then launch
"vscodium-box Restart" and check the same file now reads fine. Then confirm
that `./uninstall-vscodium.sh` tears down all three launcher/desktop pairs and
the container cleanly.

## License

See [LICENSE](LICENSE).
