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

function global:agy-acc {
    param (
        [Parameter(Position = 0)]
        [ValidateSet('switch', 'use', 'save', 'list', 'current', 'new', 'remove', 'help')]
        [string]$Action = 'list',

        [Parameter(Position = 1)]
        [ValidatePattern('^[\w.@-]+$')]
        [string]$Name,

        [switch]$Force
    )

    switch ($Action) {
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
                Write-Host "No saved profiles. Save the current one: agy-acc save <name>" -ForegroundColor Yellow
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

        default {
            Write-Host "Usage:" -ForegroundColor Yellow
            Write-Host "  agy-acc save <name>      - save the currently signed-in agy account as a profile"
            Write-Host "  agy-acc switch <name>    - switch agy to a saved profile (alias: use)"
            Write-Host "  agy-acc list             - list profiles and the active account"
            Write-Host "  agy-acc current          - show the active account"
            Write-Host "  agy-acc new              - sign out locally to add another account"
            Write-Host "  agy-acc remove <name>    - remove a saved profile"
            Write-Host "  -Force                   - skip safety checks (running agy, unsaved session)"
            Write-Host ""
            Write-Host "Don't use /logout inside agy for saved accounts - it may revoke the refresh token on Google's side." -ForegroundColor DarkYellow
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
