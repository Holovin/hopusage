# HopUsage

> **HopUsage is an unofficial fork of [OpenUsage](https://github.com/robinebers/openusage).** It is not
> the official OpenUsage and is not endorsed by or affiliated with its author.

Track your AI coding subscriptions from the macOS menu bar — native Swift edition.

## What This Fork Changes

HopUsage stays on OpenUsage **0.7.16**, the last version that tracks spend and tokens from local logs,
and adds on top:

- **Backported fixes** from OpenUsage 0.8.x (Claude Max and Ultra plan names, Claude Extra Usage in
  your billing currency, Antigravity's Gemini and Argon quotas, Ollama free plans, Grok pay-as-you-go
  in dollars, named rate limit resets, and more — see the [changelog](CHANGELOG.md)).
- **[Copilot (CLI/Desktop)](docs/providers/copilot-cli.md).** The Copilot card only reads the token
  of an editor plugin (`~/.config/github-copilot`) or the GitHub CLI (`gh`), never the login of the
  GitHub Copilot desktop app and `copilot` CLI (`~/.copilot`), so it can show a different account or
  none. This separate card reads the app's login and adds its spend per day, for the current billing
  period, and per model.
- **Different defaults:** Dark theme, 24-hour time, Reduce Animations on, Total Spend off, nothing
  pinned to the menu bar.
- **Fork build:** telemetry, self-updates, and iCloud Sync are switched off (the app is signed without
  an Apple developer certificate and isn't notarized); model prices are fetched from this repository
  instead of the original project's site.
- **Removed:** the Use button for Claude's rate limit resets (use `/rate-limit-options` in Claude Code),
  the quick-link buttons on provider cards (Status, Dashboard, Usage), and dragging metric rows on the
  dashboard (reorder them in Customize instead).

For everything else — providers, features, settings — read the
[OpenUsage 0.7.16 README](https://github.com/robinebers/openusage/blob/abf472d5dbb23645c3afbb5a0c7429606ffbdcd7/README.md)
and this repository's [docs](docs/README.md).

## Installation

Download the DMG from [Releases](https://github.com/Holovin/hopusage/releases) and drag HopUsage to
Applications. The build is universal (Apple Silicon and Intel) but not notarized by Apple, so macOS
blocks it on first launch. Run this once in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/HopUsage.app
```

There is no Homebrew cask, and the app does not update itself; see [Updates](docs/updates.md). macOS
asks for Keychain access again after every update, because the build is signed without a developer
certificate. Requires macOS 15 (Sequoia) or later.

Or build it from source:

```sh
./script/build_and_run.sh
```

That stages and launches `dist/HopUsage.app`.

## Coming From OpenUsage

HopUsage has its own app name, bundle id, and data folder, so it installs next to OpenUsage without
clashing — but it doesn't see OpenUsage's data:

- macOS asks again for access to each provider's Keychain login.
- Settings, layout, and pinned metrics start from HopUsage's defaults.
- Saved history (such as Cursor's spend history and the log-scan cache) starts empty. To keep it, quit
  both apps and copy the contents of `~/Library/Application Support/OpenUsage` into
  `~/Library/Application Support/HopUsage`. This works best from OpenUsage 0.7.x.

## Fork Releasing

A release is cut by changing [FORK_VERSION](FORK_VERSION) on `fork/v0.7-base`, for example to
`0.7.16-fork.0.8.0` (the fork's own patch number, then the last original release that was backported;
the patch number goes up for a release with only the fork's own changes), together with that
version's section in [CHANGELOG.md](CHANGELOG.md). The push runs
[fork-release.yml](.github/workflows/fork-release.yml): it builds a universal, ad-hoc signed DMG with
`script/fork_release.sh`, tags the commit, and publishes a GitHub Release. No secrets, no Developer ID,
no notarization.

## Contributing

This is a personal fork: features and providers belong in the original project, and fork-specific
fixes are welcome here. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Report security issues privately
per [SECURITY.md](SECURITY.md). The OpenUsage name and logo are covered by the
[trademark policy](TRADEMARK.md).
