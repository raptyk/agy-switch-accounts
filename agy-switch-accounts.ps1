# agy-switch-accounts.ps1
#
# Switch Google accounts in Antigravity CLI (agy) without signing in through the browser again.
#
# agy stores its session (access/refresh token + id_token) in Windows Credential Manager
# under the target "gemini:antigravity" - NOT in ~/.gemini/oauth_creds.json (that file belongs to the old Gemini CLI).
# The script keeps a copy of that credential per profile (DPAPI-encrypted, readable only by the current Windows user)
# and swaps the Credential Manager entry when switching.
#
# Install (once):   .\agy-switch-accounts.ps1 -Install
# Then:             agy-acc help

param([switch]$Install)

if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error "agy-switch-accounts is only supported on Windows (relies on Windows Credential Manager and DPAPI)."
    return
}

if (-not ('AgyAcc.WinCred' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AgyAcc {
    public static class WinCred {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct CREDENTIAL {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredWrite(ref CREDENTIAL cred, int flags);
        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredDelete(string target, int type, int flags);
        [DllImport("advapi32.dll")]
        static extern void CredFree(IntPtr cred);

        const int CRED_TYPE_GENERIC = 1;
        const int CRED_PERSIST_LOCAL_MACHINE = 2;
        const int ERROR_NOT_FOUND = 1168;

        public static byte[] Read(string target, out string userName) {
            userName = null;
            IntPtr p;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out p)) {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return null;
                throw new Win32Exception(err);
            }
            try {
                var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                userName = c.UserName;
                var blob = new byte[c.CredentialBlobSize];
                if (blob.Length > 0) Marshal.Copy(c.CredentialBlob, blob, 0, blob.Length);
                return blob;
            } finally {
                CredFree(p);
            }
        }

        public static void Write(string target, string userName, byte[] blob) {
            var c = new CREDENTIAL();
            c.Type = CRED_TYPE_GENERIC;
            c.TargetName = target;
            c.UserName = userName;
            c.Persist = CRED_PERSIST_LOCAL_MACHINE;
            c.CredentialBlobSize = blob.Length;
            c.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
            try {
                Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
                if (!CredWrite(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                Marshal.FreeHGlobal(c.CredentialBlob);
            }
        }

        public static bool Delete(string target) {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND) return false;
            throw new Win32Exception(err);
        }
    }
}
'@
}


$global:AgyAccTarget   = 'gemini:antigravity'
$global:AgyAccUser     = 'antigravity'
$global:AgyAccStoreDir = Join-Path $HOME '.agy-profiles'

# Active agy session from Credential Manager: @{ Blob; User; Email; AuthMethod } or $null.
function global:AgyAcc-ReadActive {
    $user = $null
    $blob = [AgyAcc.WinCred]::Read($AgyAccTarget, [ref]$user)
    if (-not $blob) { return $null }
    $info = AgyAcc-ParseBlob $blob
    $info.Blob = $blob
    $info.User = if ($user) { $user } else { $AgyAccUser }
    return $info
}

function global:AgyAcc-ParseBlob([byte[]]$Blob) {
    $info = @{ Email = $null; AuthMethod = $null }
    try {
        $json = [Text.Encoding]::UTF8.GetString($Blob) | ConvertFrom-Json
        $info.AuthMethod = $json.auth_method
        if ($json.id_token) {
            $payload = $json.id_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
            while ($payload.Length % 4) { $payload += '=' }
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            $info.Email = $claims.email
        }
    } catch {}
    return $info
}

function global:AgyAcc-SaveProfile([string]$Name, $Active) {
    $dir = Join-Path $AgyAccStoreDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # DPAPI (CurrentUser) - the file can only be decrypted by this Windows account.
    ConvertTo-SecureString ([Convert]::ToBase64String($Active.Blob)) -AsPlainText -Force |
        ConvertFrom-SecureString | Set-Content (Join-Path $dir 'credential.dpapi') -Encoding ascii
    [ordered]@{
        email      = $Active.Email
        authMethod = $Active.AuthMethod
        userName   = $Active.User
        savedAt    = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content (Join-Path $dir 'profile.json') -Encoding utf8
}

function global:AgyAcc-LoadProfile([string]$Name) {
    $dir = Join-Path $AgyAccStoreDir $Name
    $credFile = Join-Path $dir 'credential.dpapi'
    if (-not (Test-Path $credFile)) { return $null }
    $secure = Get-Content $credFile -Raw | ForEach-Object Trim | ConvertTo-SecureString
    $meta = Get-Content (Join-Path $dir 'profile.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    return @{
        Blob  = [Convert]::FromBase64String([Net.NetworkCredential]::new('', $secure).Password)
        User  = if ($meta.userName) { $meta.userName } else { $AgyAccUser }
        Email = $meta.email
    }
}

function global:AgyAcc-GetProfiles {
    if (-not (Test-Path $AgyAccStoreDir)) { return @() }
    Get-ChildItem -Directory $AgyAccStoreDir | Where-Object { Test-Path (Join-Path $_.FullName 'credential.dpapi') } | ForEach-Object {
        $meta = Get-Content (Join-Path $_.FullName 'profile.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        [pscustomobject]@{ Name = $_.Name; Email = $meta.email; SavedAt = $meta.savedAt }
    }
}

# agy refreshes the access token and writes it back to Credential Manager, so before swapping we copy
# the current session into the profile(s) with the same email - so profiles never hold a stale state.
function global:AgyAcc-SyncActive {
    $active = AgyAcc-ReadActive
    if (-not $active -or -not $active.Email) { return $active }
    foreach ($p in AgyAcc-GetProfiles | Where-Object Email -eq $active.Email) {
        AgyAcc-SaveProfile $p.Name $active
    }
    return $active
}

function global:AgyAcc-AssertNotRunning([switch]$Force) {
    $procs = @(Get-Process agy -ErrorAction SilentlyContinue)
    if (-not $procs -or $Force) { return $true }
    Write-Host "$($procs.Count) agy process(es) running (PID: $($procs.Id -join ', '))." -ForegroundColor Yellow
    Write-Host "A running agy keeps its token in memory and will overwrite the switched session on refresh." -ForegroundColor Yellow
    Write-Host "Close agy sessions (and 'agy remote-control stop' if used) or add -Force." -ForegroundColor Yellow
    return $false
}

# agy may leave processes behind for a few seconds after --print returns; they could still write a refreshed
# token into Credential Manager, so wait for them before swapping the credential.
function global:AgyAcc-WaitForExit([int]$TimeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (Get-Process agy -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

# Sends one prompt from each profile, so every account's usage window (5h limit) starts now.
# Restores the originally active account afterwards (also on Ctrl+C).
function global:AgyAcc-Warmup([string[]]$Names, [string]$Message, [string]$Model, [switch]$Force) {
    $original = AgyAcc-SyncActive
    if ($original -and $original.Email -and -not (AgyAcc-GetProfiles | Where-Object Email -eq $original.Email) -and -not $Force) {
        Write-Host "The active session $($original.Email) is not saved. Save it first: agy-acc save <name>  (or use -Force)." -ForegroundColor Yellow
        return $false
    }

    # Low reasoning effort - the answer itself doesn't matter, only that a message was sent.
    $agyArgs = @('--print', $Message, '--print-timeout', '15s', '--effort', 'low', '--disable-slash-commands')
    if ($Model) { $agyArgs += @('--model', $Model) }
    # Neutral, empty working directory - agy treats the current directory as its workspace.
    $workDir = Join-Path ([IO.Path]::GetTempPath()) 'agy-acc-warmup'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    # Progress log: every step gets a timestamp, so it is clear what the warmup is doing and how long it takes.
    $log = { param([string]$Text, [string]$Color = 'Gray') Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Text" -ForegroundColor $Color }
    # Waits for leftover agy processes and logs it, but only when there is something to wait for.
    $waitForAgy = {
        param([string]$Reason)
        if (-not (Get-Process agy -ErrorAction SilentlyContinue)) { return $true }
        & $log "      waiting for agy to exit ($Reason)..." DarkGray
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $exited = AgyAcc-WaitForExit
        if ($exited) { & $log ("      agy exited after {0:N1}s" -f $sw.Elapsed.TotalSeconds) DarkGray }
        else { & $log "      agy still running after 15s" Yellow }
        return $exited
    }

    $total = [Diagnostics.Stopwatch]::StartNew()
    $ok = 0; $failed = 0; $skipped = 0
    Write-Host ""
    & $log "Warming up $($Names.Count) profile(s) with '$Message' (model: $(if ($Model) { $Model } else { 'agy default' }), timeout: 15s)" Cyan
    Push-Location $workDir
    try {
        $i = 0
        foreach ($name in $Names) {
            $i++
            $target = AgyAcc-LoadProfile $name
            if (-not $target) { & $log "[$i/$($Names.Count)] $name - profile not found, skipped" Yellow; $skipped++; continue }
            & $log "[$i/$($Names.Count)] $name  $($target.Email)" White
            if (-not (& $waitForAgy 'before switching')) { & $log "      skipped" Yellow; $skipped++; continue }

            [AgyAcc.WinCred]::Write($AgyAccTarget, $target.User, $target.Blob)
            & $log "      switched credential, sending prompt..." DarkGray
            $sw = [Diagnostics.Stopwatch]::StartNew()
            # agy writes UTF-8, but PowerShell decodes native output with the console code page (e.g. 852),
            # which garbles non-ASCII characters - decode it as UTF-8 for the duration of the call.
            $consoleEncoding = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [Text.Encoding]::UTF8
                $out = (& agy @agyArgs 2>&1 | Out-String).Trim()
                $code = $LASTEXITCODE
            } finally {
                [Console]::OutputEncoding = $consoleEncoding
            }
            $elapsed = $sw.Elapsed.TotalSeconds

            $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($first -and $first.Length -gt 70) { $first = $first.Substring(0, 70) + '...' }
            if ($code -eq 0) { & $log ("      OK in {0:N1}s: {1}" -f $elapsed, $first) Green; $ok++ }
            else { & $log ("      FAILED (exit {0}) after {1:N1}s: {2}" -f $code, $elapsed, $first) Red; $failed++ }

            & $waitForAgy 'it may still save a refreshed token' | Out-Null
            AgyAcc-SyncActive | Out-Null   # keep the token agy may have refreshed
            & $log "      token synced to profile '$name'" DarkGray
        }
    } finally {
        Pop-Location
        & $waitForAgy 'before restoring' | Out-Null
        # Restore the original account - from its profile, since its token may have been refreshed meanwhile.
        $saved = if ($original -and $original.Email) { AgyAcc-GetProfiles | Where-Object Email -eq $original.Email | Select-Object -First 1 }
        if ($saved) {
            $restore = AgyAcc-LoadProfile $saved.Name
            [AgyAcc.WinCred]::Write($AgyAccTarget, $restore.User, $restore.Blob)
        } elseif ($original) {
            [AgyAcc.WinCred]::Write($AgyAccTarget, $original.User, $original.Blob)
        } else {
            [AgyAcc.WinCred]::Delete($AgyAccTarget) | Out-Null
        }
        & $log "Restored active session: $(if ($original) { $original.Email } else { '(none)' })" DarkGray
        & $log ("Done in {0:N1}s: {1} OK, {2} failed, {3} skipped" -f $total.Elapsed.TotalSeconds, $ok, $failed, $skipped) Cyan
    }
    return $true
}

# Step-by-step guide for adding an account, with a hint based on the current state.
function global:AgyAcc-ShowAddAccountGuide {
    $profiles = @(AgyAcc-GetProfiles)
    $active = AgyAcc-ReadActive
    $activeProfile = if ($active -and $active.Email) { $profiles | Where-Object Email -eq $active.Email | Select-Object -First 1 }

    # One box of the flow chart: the command to type on the left, what to do in plain words on the right.
    $step = {
        param([string]$Num, [string]$Cmd, [string[]]$Notes, [switch]$Last)
        $n = @($Notes) + @('', '')
        Write-Host "   +-------------------------+"
        Write-Host "   | $Num. " -NoNewline
        Write-Host $Cmd -NoNewline -ForegroundColor Green
        Write-Host ("{0}|   {1}" -f (' ' * (21 - $Cmd.Length)), $n[0])
        if ($Last) {
            Write-Host ("   +-------------------------+   $($n[1])".TrimEnd())
            if ($n[2]) { Write-Host "                                 $($n[2])" }
            return
        }
        Write-Host ("   +------------+------------+   $($n[1])".TrimEnd())
        Write-Host ("                |                $($n[2])".TrimEnd())
        Write-Host "                v"
    }

    Write-Host "`nHow to add another Google account" -ForegroundColor Cyan
    Write-Host "=================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  It takes about a minute: you type 3 commands and sign in once in the browser."
    Write-Host ""
    & $step 1 'agy-acc new' @(
        'Type this to make room for the new account.',
        "Don't worry - your saved accounts stay safe,",
        "nothing gets logged out on Google's side.")
    & $step 2 'agy' @(
        'Start agy. It opens the browser - now YOU sign in',
        'there with the NEW Google account. Once agy says',
        "you're in, just close agy as you normally do.")
    & $step 3 'agy-acc save work' @(
        'Give the account a short name you will remember,',
        'e.g. "work", "private", "john". You will use this',
        'name later to switch to this account.')
    & $step 4 'agy-acc list' @(
        'Check that it worked: your new name is on the list',
        'with a * next to it (that is the account in use now).') -Last
    Write-Host ""
    Write-Host "  Done! Want to add more accounts? Just repeat steps 1-4."
    Write-Host "  To jump between accounts later, type: " -NoNewline
    Write-Host "agy-acc switch <name>" -ForegroundColor Green
    Write-Host ""
    Write-Host "  One rule: don't use /logout inside agy - it can break your saved accounts." -ForegroundColor DarkYellow
    Write-Host "  'agy-acc new' (step 1) is the safe way to make room for another account." -ForegroundColor DarkYellow
    Write-Host ""

    Write-Host "Where are you now? " -NoNewline -ForegroundColor Yellow
    if (-not $active) {
        Write-Host "agy isn't signed in to any account yet - skip step 1 and start with step 2."
    } elseif (-not $activeProfile) {
        Write-Host "You're signed in as $($active.Email), but this account isn't saved yet."
        Write-Host "  Save it first so you don't lose it: " -NoNewline
        Write-Host "agy-acc save <name>" -NoNewline -ForegroundColor Green
        Write-Host " - then start with step 1."
    } else {
        Write-Host "You're signed in as $($active.Email) (saved as '$($activeProfile.Name)'), so start with step 1."
    }
    Write-Host ""
}

function global:agy-acc {
    param (
        [Parameter(Position = 0)]
        [ValidateSet('switch', 'use', 'save', 'list', 'current', 'new', 'remove', 'warmup', 'help', 'help-addaccount')]
        [string]$Action = 'help',

        [Parameter(Position = 1)]
        [ValidatePattern('^[\w.@-]+$')]
        [string]$Name,

        # warmup: prompt to send, model to use, repeat interval in hours (0 = run once).
        [string]$Message = 'hello',
        [string]$Model = 'gemini-3.8-flash-low',
        [ValidateRange(0, 168)]
        [double]$Every = 0,

        [switch]$Force
    )

    switch ($Action) {
        'warmup' {
            $names = if ($Name) { @($Name) } else { @(AgyAcc-GetProfiles | ForEach-Object Name) }
            if (-not $names) {
                Write-Host "No saved profiles. Save one first: agy-acc save <name>" -ForegroundColor Yellow
                return
            }
            if ($Every -eq 0 -and -not (AgyAcc-AssertNotRunning -Force:$Force)) { return }

            while ($true) {
                if ($Every -gt 0 -and (Get-Process agy -ErrorAction SilentlyContinue)) {
                    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] agy is running - waiting for it to exit before warming up, checking every 10s (Ctrl+C to stop)..." -ForegroundColor Yellow
                    while (Get-Process agy -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 10 }
                    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] agy closed, starting the round." -ForegroundColor Yellow
                }
                if (-not (AgyAcc-Warmup $names $Message $Model -Force:$Force)) { return }
                if ($Every -eq 0) { return }

                $next = (Get-Date).AddHours($Every)
                Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] Next round at $($next.ToString('yyyy-MM-dd HH:mm')) (Ctrl+C to stop)." -ForegroundColor Cyan
                # Short sleeps against the wall clock, so the schedule survives the PC going to sleep.
                while ((Get-Date) -lt $next) { Start-Sleep -Seconds 10 }
            }
        }

        'save' {
            if (-not $Name) {
                Write-Host "Specify a profile name, e.g.: agy-acc save account1" -ForegroundColor Yellow
                return
            }
            $active = AgyAcc-ReadActive
            if (-not $active) {
                Write-Host "No signed-in agy session ('$AgyAccTarget' in Credential Manager). Run agy and sign in." -ForegroundColor Red
                return
            }
            $dupes = AgyAcc-GetProfiles | Where-Object { $_.Email -eq $active.Email -and $_.Name -ne $Name }
            if ($dupes) {
                Write-Host "Warning: this account is already saved in profile(s): $($dupes.Name -join ', ')" -ForegroundColor Yellow
            }
            AgyAcc-SaveProfile $Name $active
            Write-Host "Saved session $($active.Email) as profile '$Name'." -ForegroundColor Green
        }

        { $_ -in 'switch', 'use' } {
            if (-not $Name) {
                Write-Host "Specify a profile, e.g.: agy-acc switch account1" -ForegroundColor Yellow
                return
            }
            $target = AgyAcc-LoadProfile $Name
            if (-not $target) {
                Write-Host "Error: profile '$Name' does not exist." -ForegroundColor Red
                agy-acc list
                return
            }
            if (-not (AgyAcc-AssertNotRunning -Force:$Force)) { return }

            $active = AgyAcc-SyncActive
            if ($active -and $active.Email -and -not (AgyAcc-GetProfiles | Where-Object Email -eq $active.Email)) {
                Write-Host "Warning: the active session $($active.Email) is not saved in any profile - it will be lost after switching." -ForegroundColor Yellow
                Write-Host "Save it first: agy-acc save <name>  (or repeat with -Force)." -ForegroundColor Yellow
                if (-not $Force) { return }
            }

            [AgyAcc.WinCred]::Write($AgyAccTarget, $target.User, $target.Blob)
            Write-Host "Switched agy to profile '$Name' ($($target.Email))." -ForegroundColor Green
        }

        'new' {
            # Local sign-out (no token revoke on Google's side), so agy asks for a new account.
            if (-not (AgyAcc-AssertNotRunning -Force:$Force)) { return }
            $active = AgyAcc-SyncActive
            if ($active -and $active.Email -and -not (AgyAcc-GetProfiles | Where-Object Email -eq $active.Email) -and -not $Force) {
                Write-Host "The active session $($active.Email) is not saved. Save it first: agy-acc save <name>  (or use -Force)." -ForegroundColor Yellow
                return
            }
            [AgyAcc.WinCred]::Delete($AgyAccTarget) | Out-Null
            Write-Host "Removed the active session from Credential Manager (saved profiles are untouched)." -ForegroundColor Green
            Write-Host "Now run 'agy', sign in with the new account, exit agy and run: agy-acc save <name>"
        }

        'remove' {
            if (-not $Name) {
                Write-Host "Specify a profile to remove, e.g.: agy-acc remove account1" -ForegroundColor Yellow
                return
            }
            $dir = Join-Path $AgyAccStoreDir $Name
            if (-not (Test-Path $dir)) {
                Write-Host "Error: profile '$Name' does not exist." -ForegroundColor Red
                return
            }
            Remove-Item $dir -Recurse -Force
            Write-Host "Removed profile '$Name' (active agy session unchanged)." -ForegroundColor Green
        }

        'current' {
            $active = AgyAcc-ReadActive
            if ($active) { Write-Host "Active agy session: $($active.Email)" -ForegroundColor Green }
            else { Write-Host "agy is not signed in." -ForegroundColor Yellow }
        }

        'list' {
            $profiles = @(AgyAcc-GetProfiles)
            $active = AgyAcc-ReadActive
            if (-not $profiles) {
                Write-Host "No saved profiles. Save the current one: agy-acc save <name>  (guide: agy-acc help-addaccount)" -ForegroundColor Yellow
            } else {
                Write-Host "`nSaved Antigravity CLI profiles:" -ForegroundColor Cyan
                foreach ($p in $profiles) {
                    $isActive = $active -and $active.Email -and $p.Email -eq $active.Email
                    $line = "  {0} {1,-16} {2}" -f ($(if ($isActive) { '*' } else { ' ' })), $p.Name, $p.Email
                    if ($isActive) { Write-Host $line -ForegroundColor Green } else { Write-Host $line }
                }
            }
            if ($active) { Write-Host "`nActive session: $($active.Email)" -ForegroundColor Green }
            else { Write-Host "`nagy is not signed in." -ForegroundColor Yellow }
            Write-Host ""
        }

        'help-addaccount' { AgyAcc-ShowAddAccountGuide }

        default {
            # With no profiles yet, adding the first account is what the user needs most.
            if (-not @(AgyAcc-GetProfiles)) {
                AgyAcc-ShowAddAccountGuide
                Write-Host "------------------------------------------------------------------------" -ForegroundColor DarkGray
            }
            Write-Host "`nagy-acc - switch Google accounts in Antigravity CLI (agy) without signing in again" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "How it works:" -ForegroundColor Yellow
            Write-Host "  agy keeps its session (access/refresh token) in Windows Credential Manager as '$AgyAccTarget'."
            Write-Host "  'save' copies that credential into a profile, 'switch' writes a saved copy back."
            Write-Host "  Before every swap the active session is synced into its profile, because agy refreshes tokens."
            Write-Host ""
            Write-Host "Where data is stored:" -ForegroundColor Yellow
            Write-Host "  $AgyAccStoreDir\<name>\credential.dpapi  - the session, DPAPI-encrypted (only this Windows user can read it)"
            Write-Host "  $AgyAccStoreDir\<name>\profile.json      - email, auth method, last save time"
            Write-Host ""
            Write-Host "Install / update:" -ForegroundColor Yellow
            Write-Host "  .\agy-switch-accounts.ps1 -Install  - adds a line to `$PROFILE that loads this script in every new terminal"
            Write-Host "  `$PROFILE points at the script file, so new terminals always get the current version - no reinstall needed."
            Write-Host "  To reload in an already open terminal: . `$PROFILE"
            Write-Host "  Windows PowerShell 5.1 and PowerShell 7 have separate `$PROFILE files - run -Install in each one you use."
            Write-Host ""
            Write-Host "Usage:" -ForegroundColor Yellow
            Write-Host "  agy-acc save <name>      - save the currently signed-in agy account as a profile"
            Write-Host "  agy-acc switch <name>    - switch agy to a saved profile (alias: use)"
            Write-Host "  agy-acc list             - list profiles and the active account"
            Write-Host "  agy-acc current          - show the active account"
            Write-Host "  agy-acc new              - sign out locally to add another account"
            Write-Host "  agy-acc remove <name>    - remove a saved profile"
            Write-Host "  agy-acc help-addaccount  - step-by-step guide for adding an account" -ForegroundColor Green
            Write-Host "  agy-acc warmup           - send 'hello' from ALL profiles, one by one, to start their 5h usage windows"
            Write-Host "  agy-acc warmup <name>    - the same, but only for one profile"
            Write-Host "      -Message <text>      - prompt to send (default: hello)"
            Write-Host "      -Model <model>       - model to use (default: gemini-3.8-flash-low, see: agy models)"
            Write-Host "      -Every <hours>       - keep running and repeat every N hours, e.g. -Every 5"
            Write-Host "  -Force                   - skip safety checks (running agy, unsaved session)"
            Write-Host ""
            Write-Host "Don't use /logout inside agy for saved accounts - it may revoke the refresh token on Google's side." -ForegroundColor DarkYellow
            Write-Host "To add another account, run 'agy-acc new' instead: it only clears the local session, so saved tokens stay valid." -ForegroundColor DarkYellow
            Write-Host "Then start agy, sign in with the new account in the browser, exit agy and run: agy-acc save <name>" -ForegroundColor DarkYellow
            Write-Host ""
        }
    }
}

Register-ArgumentCompleter -CommandName agy-acc -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    AgyAcc-GetProfiles | Where-Object Name -like "$wordToComplete*" | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', "$($_.Name) ($($_.Email))")
    }
}

if ($Install) {
    $line = ". `"$PSCommandPath`""
    $profileDir = Split-Path $PROFILE
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    $existing = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
    if ($existing -and $existing.Contains($line)) {
        Write-Host "Already installed in $PROFILE" -ForegroundColor Green
    } else {
        Add-Content -Path $PROFILE -Value $line
        Write-Host "Added to $PROFILE :`n  $line" -ForegroundColor Green
    }
    Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue
    Write-Host "Done - agy-acc is available in this terminal and in every new one. See: agy-acc help"
}
