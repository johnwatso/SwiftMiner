# Security Policy

## Supported Versions

The following versions of SwiftMiner are currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| < 1.0   | :x:                |

### Security Guarantees
- **No Password Storage:** SwiftMiner uses the official **Twitch OAuth Device Flow**. Your Twitch password is never entered, handled, or stored by the application.
- **Local Encrypted Storage:** OAuth tokens are stored in a locally encrypted file (`accounts.enc`) within your Application Support directory. 
- **Hardware-Locked Encryption:** Data is encrypted using **AES-256-GCM**. The encryption key is derived using HKDF from your machine's unique Hardware UUID, ensuring the data cannot be decrypted if moved to another device.
- **Direct Connection:** All mining activity and API calls are made directly to Twitch from your local machine. No account data, tokens, or watch history are proxied through or stored on external servers.

### Security Scope & Limitations
- **At-Rest Protection:** The current hardware-based encryption is designed to prevent your data from being decrypted if it is copied to or accessed from another device (e.g., via a stolen hard drive or cloud backup).
- **System-Level Access:** The Hardware UUID used for key derivation is accessible to other software running on your Mac. While this provides robust protection against offline theft, it does not offer the same level of process-isolation as the Apple Secure Enclave.
- **Future Improvements:** A migration to native macOS Keychain Services (`SecItem`) is planned for a future release to leverage OS-level key management and improved security isolation.
