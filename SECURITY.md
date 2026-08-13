# Security Policy

## Supported Versions

The following versions of SwiftMiner are currently being supported with security updates.

| Version   | Supported          | Token Storage                                            |
| --------- | ------------------ | -------------------------------------------------------- |
| ≥ 1.30    | :white_check_mark: | Native macOS Keychain                                    |
| 1.0 – 1.29 | :warning:          | Legacy hardware-UUID encrypted file — **upgrade advised** |
| < 1.0     | :x:                | Unsupported                                              |

> [!WARNING]
> **Versions prior to 1.30** store OAuth tokens in a locally encrypted file keyed to your hardware UUID rather than in the macOS Keychain. These releases still function, but no longer receive security updates and lack the OS-managed key protection of 1.30+. Upgrading to **1.30 or newer** performs a one-time, automatic migration of your accounts into the Keychain (see [Storage Migration](#storage-migration)). We strongly recommend running the latest release.

### Security Guarantees
- **No Password Storage:** SwiftMiner uses the official **Twitch OAuth Device Flow**. Your Twitch password is never entered, handled, or stored by the application.
- **Keychain Token Storage:** OAuth tokens are stored in the native **macOS Keychain** via Keychain Services (`SecItem`). Each account is held as its own generic-password item under the `com.swiftminer.accounts` service, keyed by its stable Twitch user ID. The OS manages the encryption keys, so SwiftMiner never handles raw key material.
- **Device-Only Access:** Keychain items are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so tokens are never synced to iCloud Keychain and never leave the device — they are not included in encrypted backups that could be restored elsewhere.
- **Direct Connection:** All mining activity and API calls are made directly to Twitch from your local machine. No account data, tokens, or watch history are proxied through or stored on external servers.
- **Revocation on Removal:** Removing an account revokes its OAuth grant at Twitch (`https://id.twitch.tv/oauth2/revoke`), then deletes its Keychain item and its local records. Revocation is best effort by design: if the device is offline or Twitch is unreachable, the local deletion still completes, and the grant can be removed from Twitch's [Connections](https://www.twitch.tv/settings/connections) page.

### Storage Migration
- **One-Time Import:** Older releases stored tokens in a hardware-UUID–derived, AES-256-GCM encrypted file (`accounts.enc`) in your Application Support directory. On first launch of a Keychain-enabled release, accounts are migrated into the Keychain automatically. The migration is idempotent, non-clobbering (it only imports when the Keychain is empty), and verified before being marked complete.
- **Legacy Backup:** The original `accounts.enc` file is left untouched on disk as a backup after migration. SwiftMiner periodically offers to delete it, or you may remove it manually.

### Web Dashboard
SwiftMiner includes an optional self-service web dashboard that is **disabled by default**. When it is not configured, none of the following applies and no web credentials exist.

- **Local Sign-In Credentials:** When the operator enables local username/password sign-in, the password is stored two ways for two distinct purposes:
  - A **salted, iterated hash** (PBKDF2-style chain of HMAC-SHA256, 210,000 iterations, encoded as `iterations:salt:hash`) is what actually authenticates web sign-ins. It is verified in constant time and is the only form consulted during login.
  - The **plaintext password** is held in the macOS Keychain (`com.swiftminer.app.web-dashboard.local-password` service, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) solely so the Settings UI can show the operator their current password. It is never used to authenticate.
- **Local-Only by Design:** Local username/password sign-in is only honoured for local/LAN requests — it is rejected when the request arrives over the public domain, so the operator password never works across the internet.
- **OAuth Identities:** Other sign-in methods (Twitch OAuth, and Discord brokered through SwiftBot SSO) carry no passwords. SwiftMiner stores no Discord credentials of its own.
- **Session Security:** Web sessions are opaque, server-side, and carried in an `HttpOnly; SameSite=Lax` cookie. `Secure` is set whenever the dashboard is reached over its public HTTPS domain; it is omitted for local sign-in, which is served over plain HTTP on the LAN and would otherwise drop the cookie. Sessions expire after 7 days and expired records are purged server-side. Identity is derived only from the session — never from a forgeable URL parameter — and state-changing requests require a constant-time-checked CSRF header. OAuth sign-ins are bound to a single-use `state` value that expires after 10 minutes. A signed-in user can only address their own mined account.
- **Account Removal:** A signed-in user can delete their own account from the dashboard. The action requires a typed confirmation that is re-checked on the server, not just in the browser, so a crafted request cannot bypass it, and it carries the same CSRF requirement as any other state-changing request. A Discord-authenticated user may only remove the Twitch account they own; the local operator sign-in cannot remove accounts at all. Removal follows the same revoke-then-delete path described under [Security Guarantees](#security-guarantees), and is recorded in the Activity Log.

### Security Scope & Limitations
- **At-Rest Protection:** Keychain items inherit macOS's at-rest encryption, which is tied to your login credentials and device hardware. Tokens cannot be read from a copied disk image or backup without unlocking that device.
- **Process Access:** Tokens are readable by SwiftMiner and by other software running under your user account that can query the login Keychain. This is the standard macOS Keychain trust model and does not provide the per-process isolation of the Apple Secure Enclave.
- **Sign-In Attempts:** Local dashboard sign-in is not rate limited or locked out after repeated failures; failed attempts are recorded in the Activity Log instead. The exposure is bounded by the local-only rule above — the password is rejected outright over the public domain — so an attacker must already be on your local network to try it. Choose a strong operator password on an untrusted LAN.
- **Development Builds:** DEBUG builds intentionally do **not** touch the real login Keychain. They continue to use the legacy hardware-UUID encrypted file so local development never writes to your production Keychain. The data-protection Keychain (`kSecUseDataProtectionKeychain`) is not used because it requires a `keychain-access-groups` entitlement that is unavailable in unsigned local and test builds.
