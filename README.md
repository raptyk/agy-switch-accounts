# agy-switch-accounts

Switch Google accounts in Antigravity CLI (`agy`) without signing in through the browser again.

> [!IMPORTANT]
> **Platform: Windows only**  
> This tool specifically relies on the Windows Credential Manager (`advapi32.dll` / `CredRead`/`CredWrite`) and Windows Data Protection API (DPAPI) to securely store and swap credentials. It is not supported on Linux or macOS.

## How it works

`agy` stores its session (access token, refresh token and id_token) in Windows Credential Manager under the generic credential `gemini:antigravity`.

- **Saving a profile:** the script copies that credential to `~/.agy-profiles/<name>/credential.dpapi`. The copy is encrypted with DPAPI, so only the current Windows user can decrypt it. The account email (read from the id_token), auth method and save time go to `profile.json` next to it.
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

`$PROFILE` dot-sources the script from this folder, so after an update new terminals load the new version automatically. In a terminal that's already open, reload it with `. $PROFILE`. Windows PowerShell 5.1 and PowerShell 7 use separate `$PROFILE` files, so run `-Install` in each shell you use.

```powershell
agy-acc save account1      # save the currently signed-in account
agy-acc new                # clear the local session (no token revoke)
agy                        # sign in with another account, then exit
agy-acc save account2
agy-acc switch account1    # switch without the browser
agy-acc list               # list profiles; * marks the active one
agy-acc current            # show the active account
agy-acc remove account2
agy-acc help-addaccount    # step-by-step guide for adding an account
```

`agy-acc` with no arguments shows help. If no profiles are saved yet, it shows the add-account guide first.

Don't use `/logout` inside `agy` for saved accounts. It may revoke the refresh token and break the saved profile.
To add another account, run `agy-acc new` instead: it only clears the local session, so the saved tokens stay valid. Then start `agy`, sign in with the new account in the browser, exit `agy` and run `agy-acc save <name>`.

### Warm-up mode

Usage limits run in 5-hour windows that start with the first message. `warmup` switches through the saved profiles one by one, sends a short prompt from each (`agy --print`), and then restores the account that was active before. That way every account's window starts now, not when you first need it.

```powershell
agy-acc warmup                     # all profiles, one by one, once
agy-acc warmup account1            # a single profile
agy-acc warmup -Model claude-sonnet-4-6   # start the window for a specific model (default: gemini-3.8-flash-low)
agy-acc warmup -Every 5            # keep running: repeat every 5 hours (Ctrl+C to stop)
agy-acc warmup -Message "hi"       # a different prompt
```

The prompt runs in an empty temp directory, so `agy` doesn't treat your project as the workspace. Refreshed tokens are saved back into each profile. In `-Every` mode the script waits while `agy` is running and starts the round once it exits.
