# AGENTS.md

OpenUsage is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Fork

This repository is HopUsage, an unofficial fork of OpenUsage. The rules below override anything later in
this file that contradicts them.

- **Base:** the fork stays on the 0.7 line. `fork/v0.7-base` is the main branch and always holds the
  newest backport. `main` only mirrors the original project; never commit to it.
- **Backports:** each original release, betas included, is backported on its own branch named
  `fork/v0.7-backport-v<version>`, cut from `fork/v0.7-base`. For each release: research what changed,
  group it by feature, agree with the owner on what to port, then port it. When a backport is done,
  `fork/v0.7-base` moves to it.
- **Switched off, keep off:** the Sparkle updater, PostHog telemetry, and iCloud Sync, each behind a
  flag with a comment. The original workflows live in `.github/workflows-disabled/`.
- **Renamed:** the app name, bundle ids, the bundled executable, the `hopusage` command, config paths,
  and the JSON schema. **Not renamed, leave as is:** SwiftPM targets and folders (`OpenUsage*`), the log
  subsystem, and `openusage.*` settings keys, so backports conflict less.
- **Commits:** fork-only changes use the `chore(fork):` prefix, one concern per commit.
- **Releases:** the version lives in `FORK_VERSION` as `0.7.16-fork.<original version>`, e.g.
  `0.7.16-fork.0.8.0`. A push to `fork/v0.7-base` that changes the file runs
  `.github/workflows/fork-release.yml`: it builds a universal, ad-hoc signed, un-notarized DMG with
  `script/fork_release.sh`, tags the commit `v<version>`, and publishes a GitHub Release (a pre-release
  when the original version is a beta). Nothing is released while the tag already exists. Never push
  release tags by hand, and never change `FORK_VERSION` on your own initiative; the owner decides when
  to release. The bump is its own commit, `chore(fork): bump version to <version>`.
- The Releases section below describes the original pipeline. It does not run in this fork.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of OpenUsage. Active development happens on the `main` branch. (NOT the legacy Tauri version which now sits in the `tauri-legacy` branch)

## Releases

`main` is the active development line; it ships via `.github/workflows/release.yml` (Sparkle appcast on `gh-pages`). Cut releases with the release-swift skill.

### Guardrails (do not break)
- Versions are `0.7.x` and up. Never reuse a `0.6.x` number — those are the original edition's released tags, now frozen on the `tauri-legacy` branch (final release `v0.6.28`).
- **Never increase the version number on your own initiative — always ask for explicit approval first.** The version is a deliberate owner decision: propose the number and wait for explicit sign-off before tagging or cutting a release.
- Beta releases use `-beta.N` tags and stay GitHub pre-releases on Sparkle's beta channel. Stable releases use plain tags and become GitHub "Latest".
- Stable releases must carry forward the legacy `latest.json` so any remaining `0.6.x` installs can still update to `v0.6.28`. `release.yml` handles this; verify it with the release-swift skill.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the changelog and verifies the published release after every cut.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Providers

Conventions for the per-provider modules under `Sources/OpenUsage/Providers/<Name>/`.

- **Structure:** one folder per provider with an auth store (reads credentials already on the user's machine), a usage client (calls the provider API), and a mapper (normalizes to `MetricLine`), conforming to `ProviderRuntime` — `refresh()` plus `hasLocalCredentials()`, the local-only credential probe used by the welcome screen's detection (`FirstLaunchSetup`) and by new-provider detection on the first launch after the provider ships (`NewProviderSeeder`); mirror the same local credential sources and usability filters that `refresh()` starts with, reusing the auth-store loaders instead of adding a second credential-reading path. See `docs/adding-a-provider.md` and `docs/provider-enablement.md`.
- **Model pricing:** all spend imputation (Claude, Codex, Cursor, Grok) prices through the shared engine in `Sources/OpenUsage/Pricing/` (see `docs/pricing.md`). Cursor-native model rates and alias rules live in `Sources/OpenUsage/Resources/pricing_supplement.json` — sync new or changed models from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md) (update `updated_at`, pricing entries, and `alias_rules` for CSV model slugs); merging to `main` publishes it to gh-pages, so installed apps pick it up without a release. The bundled LiteLLM/models.dev snapshots regenerate with `script/update_pricing_snapshots.sh` (a release-time chore).
- **Default order:** Claude, Codex, Cursor first (the established providers, in that order), then every other provider alphabetically by display name (Antigravity, Devin, Grok, …). The order is the array order in `AppContainer`, which seeds `LayoutStore`'s default provider order (and `resetToDefault`). A new provider slots into the alphabetical tail.
- **Metric placement defaults:** when adding or changing a metric, confirm its four defaults with the owner before choosing — never pick silently:
  1. enabled on/off (`DefaultLayout.metricIDs`),
  2. Always Visible vs. On Demand — above the fold vs. behind the per-provider caret (`DefaultLayout.expandedMetricIDs`). Note: a provider always keeps at least one Always Visible row — the dashboard promotes all metrics when every one is marked On Demand, so a fully On Demand provider isn't possible; leave one metric Always Visible for the caret to appear,
  3. pinned to the menu bar (`DefaultLayout.pinnedMetricIDs`),
  4. order (within a provider, the `widgetDescriptors` declaration order).

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before testing.

## Pull Requests

Every PR description must follow this structure so reviewers can skim it quickly:

- **TL;DR** — open with a one- or two-sentence plain-English summary of the change.
- **What was happening** — plain-English bullet points describing the prior behavior, bug, or gap that motivated the change.
- **What this changes** — bullet points describing what the PR actually changes.
- **Heads-up** (optional) — noteworthy things a reviewer or future maintainer should consider (risks, follow-ups, trade-offs).
- **Tests** (optional) — how the change was verified.
- **Screenshots** (optional in general, but **required for any PR that makes a visual change**) — images of the affected UI after the change.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- Add a regression test when fixing a bug, where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- When adding a provider, follow the conventions in "## Providers".

## Error Handling

Always fail loudly into error logging (log file, PostHog) and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing design language; OpenUsage has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
