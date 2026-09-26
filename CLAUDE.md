# CLAUDE.md

## Project Overview
`agy-switch-accounts` is a PowerShell tool for managing and switching Google accounts in Antigravity CLI (`agy`) without needing to re-authenticate via browser.

**Target Platform:** Windows only (Windows PowerShell 5.1 / PowerShell 7+ on Windows).

## How It Works
- **Credential Storage:** `agy` stores authentication tokens (access token, refresh token, id_token) in Windows Credential Manager under generic credential `gemini:antigravity`.
- **Profiles:** Stored in `~/.agy-profiles/<name>/credentials.dpapi` encrypted via Windows DPAPI (`DataProtectionScope.CurrentUser`).
- **Session Sync:** Before switching, the active session is synced back to the current profile. Switching is blocked if `agy` process is running or active session is unsaved (unless `-Force` is provided).
- **Shell Integration:** Loaded into PowerShell via `$PROFILE` using `.\agy-switch-accounts.ps1 -Install` which registers function `agy-acc`.
- **Platform Constraint:** Relies on Win32 API (`advapi32.dll`: `CredRead`, `CredWrite`, `CredDelete`) and Windows DPAPI, hence it cannot run directly on Linux or macOS.

## Key Commands
- `agy-acc save <name>`: Saves currently logged-in account to a named profile.
- `agy-acc switch <name>`: Switches active account to the specified profile.
- `agy-acc list`: Lists all saved profiles, indicating the currently active one with `*`.
- `agy-acc new`: Clears local session (without revoking tokens) to allow logging into a new account with `agy`.
- `agy-acc remove <name>`: Deletes a saved profile.
- `agy-acc status`: Displays current session status and active account email.
