# Security Policy

HopUsage is an unofficial fork of [OpenUsage](https://github.com/robinebers/openusage). Report a
vulnerability that also affects the original project to its maintainers as well.

## Reporting a Vulnerability

Do not open a public issue. Use GitHub's private reporting instead:

1. Go to the [Security Advisories page](https://github.com/Holovin/hopusage/security/advisories/new)
2. Click "Report a vulnerability"
3. Fill in the details

## What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Impact assessment (what can an attacker do?)

## Scope

In scope:

- The HopUsage desktop application
- The built-in providers (credential handling, API calls)
- The local HTTP API

Out of scope:

- Third-party provider APIs (report to the provider directly)
- Social engineering attacks
- Denial of service attacks

## Supported Versions

Only the latest state of the `fork/v0.7-base` branch is supported. This is a personal fork with no
response-time guarantee.
