# Security

OpenShade XIV downloads files and writes them into a game folder, so a problem with how it does that is best reported privately first.

## Reporting a problem

Please do not open a public issue for a security problem. Use **Report a vulnerability** on the [Security tab](https://github.com/divinepleroma/openshade-xiv/security/advisories/new) of this repository. The report stays private until a fix is released.

Examples of what to report:

- A way to make the tool use a download that does not match the checksums in `manifest.json`.
- A package or path that gets past the checks and is written outside the game folder.
- A release zip that does not match this repository.

## Supported versions

Only the [latest release](https://github.com/divinepleroma/openshade-xiv/releases/latest) is supported. Fixes are published as a new release.

## Out of scope

Problems in ReShade or GPosingway themselves belong with those projects:

- [ReShade](https://github.com/crosire/reshade)
- [GPosingway](https://github.com/gposingway/gposingway)
