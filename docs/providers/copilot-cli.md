# Copilot (CLI/Desktop)

A second Copilot card that tracks the account signed in to the **GitHub Copilot desktop app** and the `copilot` command-line tool. Use it when that account differs from the one your editor or the GitHub CLI (`gh`) is signed in to — the regular [Copilot](copilot.md) card reads those instead.

## What it tracks

The same meters as [Copilot](copilot.md): Credits, Extra Usage, Org Credits, Org Spend, Chat, and Completions. Only Credits is on by default; the others are On Demand and off until you turn them on in Customize. Plan differences and org-managed seats behave exactly as described there.

It also shows your local usage from the app and the CLI:

| Metric | Meaning |
|---|---|
| Usage Trend | Tokens used per day over the last 30 days |
| This Period | What you've spent since the current billing period began (the day the Credits meter last reset), with the per-model breakdown on hover |
| Today / Yesterday / Last 30 Days | What the requests cost and how many tokens they used, e.g. `$2.94 · 10.5M tokens`; hover for the per-model breakdown |

By default the card shows Credits, Today, Yesterday, Usage Trend, and This Period, in that order; Last 30 Days is On Demand and off. Last 30 Days is a rolling window, so it can span two billing periods — This Period is the one to compare with the Credits meter. It only counts this Mac's app and CLI usage, so it can be lower than what the meter shows if you also use Copilot elsewhere. The dollars are the AI credits Copilot itself charged for each request (one credit is $0.01), not an estimate, so they carry no ⓘ and count toward Total Spend. A day with no usage reads **No data**.

## Where credentials come from

1. `~/.copilot/config.json` names the signed-in account (`lastLoggedInUser`, otherwise the first `loggedInUsers` entry). Only github.com accounts are used.
2. The token is read from the Keychain item the app saves: service `copilot-cli`, account `https://github.com:<login>`.

The first read asks for Keychain access once; choose **Always Allow**.

### Setup

Sign in to the GitHub Copilot desktop app, or run `copilot` and use `/login`.

## Troubleshooting

- **"Sign in to the GitHub Copilot app…"** — no signed-in github.com account or no Keychain item was found. Sign in to the app again.
- **"GitHub Copilot app token invalid or expired"** — the token was rejected (401/403). Sign out and back in to the app.
- **Keychain access denied** — you chose **Deny** on the Keychain prompt, so HopUsage stops asking until you refresh manually. Refresh and choose **Always Allow**.

## Under the hood

Same API calls as [Copilot](copilot.md); only the token source differs. The remembered billing org is stored per card.

The usage rows read the `assistant_usage_events` table in `~/.copilot/session-store.db`, which the app and the CLI write one row per model request: tokens are `input_tokens + output_tokens` (input already includes cache reads and writes, output includes reasoning), credits are `total_nano_aiu` divided by 10⁹, and dollars are credits × $0.01. Each row's `model` feeds the per-model breakdown. Some sessions never reach that database (certain CLI builds skip it), so HopUsage also reads each session's `~/.copilot/session-state/<session>/events.jsonl`, where every request is logged as a `session.usage_record` event, and adds the requests the database doesn't already hold (matched by session, model, and token counts). Logs are re-read only when they change. This Period starts one calendar month (UTC) before the Credits reset date, or on the 1st of the current UTC month when the response has no reset date. Read-only; nothing leaves your Mac.
