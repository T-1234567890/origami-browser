# Security policy

Origami is currently **Beta / pre-release software**. Security boundaries are still being tested and hardened; there is no stable-release support matrix yet.

## Reporting a vulnerability

Please coordinate with the maintainers before publicly disclosing an exploitable vulnerability. Do not put exploit details in public issues, pull requests, discussions, or public attachments.

Use GitHub's **Security → Report a vulnerability** action on [the canonical repository](https://github.com/T-1234567890/origami-browser/security) if GitHub makes that action available to you. Its availability is not currently confirmed for this private repository.

There is no dedicated security email published here. If the private reporting action is unavailable, use an existing private channel to a maintainer. If you have no such channel, open an issue titled **“Private security reporting contact requested”** containing only a request for a private reporting route—no vulnerability details, affected targets, exploit code, or sensitive attachments. Wait for a private channel before sending the report.

## What to include privately

Provide the macOS version, Origami build or commit, affected component, expected behavior, actual behavior, and concise reproduction steps using a synthetic test page or disposable data. Describe the likely impact and any workaround you have found. A minimal sanitized proof of concept is helpful.

**Never include real API keys, passwords, session cookies, access tokens, or sensitive browsing data.** Redact credentials and personal details from URLs, logs, screenshots, and attachments. If the issue requires a credential-like value, use an unmistakably fake placeholder rather than a live secret.

## Scope

Security reports include issues involving:

- Credential and AI API-key handling.
- WebKit/native bridges and unintended native capabilities.
- Generated Visual sandbox escapes or resource-exhaustion weaknesses.
- Private Browsing data leakage and profile isolation.
- `origami://` privilege boundaries and unsafe URL handling.
- Unsafe downloads, destination handling, and quarantine bypasses.
- Update integrity or signing issues, including any update mechanism introduced later.

Ordinary website compatibility problems, visual glitches, and feature requests generally belong in regular issues. A compatibility problem that exposes data or crosses a security boundary should instead follow this private reporting process.

## Current limitations

Generated Visuals use an isolated nonpersistent WebView, restrictive content policy, and failure-driven environment disposal. Public WebKit APIs do not provide a hard CPU/memory quota or guarantee immediate process termination. Please report containment bypasses privately.

Private Browsing limits local retention; it does not hide activity from websites, network operators, or an AI provider receiving a request. Explicitly saved bookmarks and downloaded files remain after a private window closes.
