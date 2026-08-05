# Security Policy

## Supported versions

The latest stable release receives security fixes. Pre-release builds are supported on a best-effort basis and must not be used to protect high-value secrets.

## Reporting

Do not open a public issue for a suspected vulnerability. Until a private reporting address is configured, contact a maintainer privately through the repository host and request a secure channel. We aim to acknowledge reports within three business days and provide an initial assessment within seven.

## Security boundaries

Keyestro is not sandboxed in v1. Scripts and native extensions are trusted local code with approximately the current user's authority. Process isolation protects the host from crashes and protocol failures; it does not make malicious extensions safe. Keyestro never loads third-party native libraries into its process and never removes quarantine or bypasses Gatekeeper.

Secrets and clipboard encryption keys belong in Keychain. Queries, clipboard bodies, screenshots, passwords, and file contents must not enter normal logs, analytics, configuration exports, or bug reports.
