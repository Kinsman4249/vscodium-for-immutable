# Changelog

This file tracks real changes to this repository, grouped by round of work.
For the formatting rules these entries follow, see CHANGELOG_TEMPLATE.md in
Kinsman4249/.github-private.

### Initial VSCodium installer and project setup (round one)

1. Added install-vscodium.sh, a one-click installer/updater that creates a Debian 12 Distrobox container named vscodium-box, installs VSCodium from its official apt repository (download.vscodium.com) with a signed-by-pinned signing key following the instructions published at vscodium.com, and exports the app to the host's application launcher via distrobox-export. The script is idempotent - re-running it updates VSCodium in place - and supports --remove to tear down the container and exported app cleanly, plus --debug for a full command trace. It is modeled on the sibling claude-desktop-for-immutable installer but deliberately ships none of that project's Cowork/QEMU/vhost_vsock virtualization tooling, since VSCodium does not need it.

2. The installer also provisions git and the GitHub CLI (gh) inside the same container, so VSCodium's built-in source control and any integrated-terminal or agent workflows have them available. git comes from Debian's own repositories; gh is installed from GitHub's official apt repository (cli.github.com) with its own signed-by-pinned keyring, because Debian 12 does not carry gh in its standard repositories.

3. Added a patch_launcher_flags step, run after every distrobox-export, that inserts --disable-gpu-compositing into the exported launcher's Exec= line. This works around the same Electron GPU-process repaint bug the sibling project hit on hybrid Intel+NVIDIA hardware, where text renders garbled or ghosted; disabling only GPU compositing (rather than all acceleration) clears it. The sed is written to match only the codium command after distrobox-enter's "--" separator, never the "-n vscodium-box" container name, which also contains the substring "codium". README.md documents how to remove the flag if a given machine doesn't need it.

4. Added project scaffolding adapted from the Kinsman4249/.github-private templates: README.md describing the purpose, mechanism, prerequisites, usage, and GPU note; community health files (CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md); .github/ issue and pull-request templates; a release.yml workflow that bundles tagged commits into .tar.gz/.zip archives on vX.Y.Z tag pushes; a .gitignore that skips session files (handoff.md, todo.md, .claude/); and this CHANGELOG.md.
