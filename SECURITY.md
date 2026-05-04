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
- **No Password Storage:** SwiftMiner uses the official **Twitch OAuth Device Flow**. Your Twitch password is never entered, handled, or stored by the application.
- **Local Encrypted Storage:** OAuth tokens are stored in a locally encrypted file (`accounts.enc`) within your Application Support directory. 
- **Hardware-Locked Encryption:** Data is encrypted using **AES-256-GCM**. The encryption key is derived using HKDF from your machine's unique Hardware UUID, ensuring the data cannot be decrypted if moved to another device.
- **Direct Connection:** All mining activity and API calls are made directly to Twitch from your local machine. No account data, tokens, or watch history are proxied through or stored on external servers.
