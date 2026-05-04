# Security Policy

## Supported Versions

The following versions of SwiftMiner are currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

I take the security of your Twitch accounts and data seriously. If you discover a security vulnerability within SwiftMiner, please follow these steps:

1. **Do not** open a public GitHub issue for vulnerabilities.
2. Email your report to the maintainer or use the GitHub "Report a vulnerability" feature if enabled.
3. Provide a detailed description of the issue, including steps to reproduce.

### Security Guarantees
- **No Password Storage:** SwiftMiner uses Twitch OAuth Device Flow. Your Twitch password is never entered or stored within the app.
- **Keychain Storage:** OAuth tokens are stored securely in the macOS Keychain.
- **Direct Connection:** All API calls are made directly to Twitch from your machine. No account data is proxied through external servers.
