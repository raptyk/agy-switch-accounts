# agy-switch-accounts

Switch Google accounts in Antigravity CLI (`agy`) without signing in through the browser again.

> [!IMPORTANT]
> **Platform: Windows only**  
> This tool specifically relies on the Windows Credential Manager (`advapi32.dll` / `CredRead`/`CredWrite`) and Windows Data Protection API (DPAPI) to securely store and swap credentials. It is not supported on Linux or macOS.

## How it works

`agy` stores its session (access token, refresh token and id_token) in Windows Credential Manager under the generic credential `gemini:antigravity`.

- **Saving a profile:** the script copies that credential to `~/.agy-profiles/<name>/`. The copy is encrypted with DPAPI, so only the current Windows user can decrypt it. The account email is read from the id_token.
- **Switching:** the script writes the saved credential back into Credential Manager.
- **Before switching:** it syncs the active session into the matching profile, because `agy` refreshes tokens. It refuses to switch while `agy` is running, or when the active session isn't saved in any profile (use `-Force` to override).

## Requirements

- **Operating System:** Windows 10 / 11 / Windows Server
- **Shell:** Windows PowerShell 5.1 or PowerShell Core 7+ on Windows
- **Antigravity CLI:** `agy` installed and logged into at least once

## Usage

```powershell
.\agy-switch-accounts.ps1 -Install   # once: adds a dot-source line to $PROFILE
```

`agy-acc` is available immediately in the current terminal and in new ones.

```powershell
agy-acc save account1      # save the currently signed-in account
agy-acc new                # clear the local session (no token revoke)
agy                        # sign in with another account, then exit
agy-acc save account2
agy-acc switch account1    # switch without the browser
agy-acc list               # list profiles; * marks the active one
agy-acc remove account2
```

Don't use `/logout` inside `agy` for saved accounts. It may revoke the refresh token and break the saved profile.
