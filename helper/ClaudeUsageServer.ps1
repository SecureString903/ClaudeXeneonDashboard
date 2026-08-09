# ============================================================
#  Claude Usage Widget - local helper server  (v1.2)
#  Serves your Claude subscription usage on http://127.0.0.1:8787
#  for the Corsair Xeneon Edge widget.
#
#  v1.2: automatically renews the login using the stored refresh
#  token (the same way Claude Code does), so you never need to
#  open a terminal to refresh it.
#
#  Endpoints:
#    /usage   -> JSON usage data (proxied from Anthropic, cached 60s)
#    /        -> the dashboard page (same UI as the widget)
#    /health  -> "ok"
# ============================================================

$Port = 8787
$CacheSeconds = 60
$OAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'   # Claude Code public client id
$TokenUrls = @('https://console.anthropic.com/v1/oauth/token', 'https://platform.claude.com/v1/oauth/token')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:CachedBody = $null
$script:CachedAt   = [DateTime]::MinValue
$script:CredPath   = $null

# ---------------- credential discovery ----------------

function Find-CredentialFile {
    $candidates = New-Object System.Collections.Generic.List[string]

    # Manual override: a token.txt next to this script (contents = an sk-ant-oat... token)
    $tokenTxt = Join-Path $PSScriptRoot 'token.txt'
    if (Test-Path $tokenTxt) { return $tokenTxt }

    if ($env:CLAUDE_CONFIG_DIR) { $candidates.Add((Join-Path $env:CLAUDE_CONFIG_DIR '.credentials.json')) }
    $candidates.Add((Join-Path $env:USERPROFILE '.claude\.credentials.json'))

    # WSL distros (Claude Code running inside WSL keeps its login in the Linux filesystem)
    try {
        $distros = & wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
        foreach ($d in $distros) {
            foreach ($root in @("\\wsl.localhost\$d", "\\wsl$\$d")) {
                $homeBase = Join-Path $root 'home'
                if (Test-Path $homeBase -ErrorAction SilentlyContinue) {
                    Get-ChildItem $homeBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $candidates.Add((Join-Path $_.FullName '.claude\.credentials.json'))
                    }
                    $candidates.Add((Join-Path $root 'root\.claude\.credentials.json'))
                    break
                }
            }
        }
    } catch { }

    $existing = @($candidates | Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) })
    if ($existing.Count -eq 0) { return $null }
    return ($existing | Sort-Object { (Get-Item $_).LastWriteTime } -Descending | Select-Object -First 1)
}

function Get-CredentialState {
    if (-not $script:CredPath -or -not (Test-Path $script:CredPath -ErrorAction SilentlyContinue)) {
        $script:CredPath = Find-CredentialFile
    }
    if (-not $script:CredPath) {
        $msg = "Claude Code login not found. Checked $env:USERPROFILE\.claude, CLAUDE_CONFIG_DIR, and WSL home folders. " +
               "Run 'claude' in a terminal (Windows or WSL) and log in once, then this page will recover by itself."
        throw $msg
    }

    if ((Split-Path $script:CredPath -Leaf) -eq 'token.txt') {
        $tok = (Get-Content -Path $script:CredPath -Raw).Trim()
        if (-not $tok) { throw 'token.txt is empty.' }
        return @{ Path = $script:CredPath; IsTokenTxt = $true; Raw = $null
                  Creds = [pscustomobject]@{ accessToken = $tok } }
    }

    $raw = Get-Content -Path $script:CredPath -Raw | ConvertFrom-Json
    $creds = $null
    if ($raw.claudeAiOauth) { $creds = $raw.claudeAiOauth }
    elseif ($raw.accessToken) { $creds = $raw }
    if (-not $creds) {
        $badPath = $script:CredPath
        $script:CredPath = $null
        throw "Could not find an OAuth token inside $badPath."
    }
    return @{ Path = $script:CredPath; IsTokenTxt = $false; Raw = $raw; Creds = $creds }
}

# ---------------- token refresh ----------------

function Test-TokenExpiringSoon($creds) {
    if (-not $creds.expiresAt) { return $false }
    try {
        $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([long][double]$creds.expiresAt)
        return ($exp -lt [DateTimeOffset]::Now.AddMinutes(2))
    } catch { return $false }
}

function Invoke-TokenRefresh($state) {
    # Renews the login exactly the way Claude Code does, and writes the
    # renewed tokens back to .credentials.json so they persist (and so
    # Claude Code, if you ever use it, picks them up too).
    if ($state.IsTokenTxt) { return $false }
    if (-not $state.Creds.refreshToken) { return $false }

    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $state.Creds.refreshToken
        client_id     = $OAuthClientId
    } | ConvertTo-Json

    $resp = $null
    foreach ($url in $TokenUrls) {
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' `
                     -Headers @{ 'User-Agent' = 'claude-code/2.0.31'; 'Accept' = 'application/json' } `
                     -Body $body -TimeoutSec 20
            break
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 404) { continue }   # endpoint moved -> try next URL
            Write-Host "Token refresh failed ($status): $($_.Exception.Message)"
            return $false
        }
    }
    if (-not $resp -or -not $resp.access_token) { return $false }

    $newExpiresAt = [DateTimeOffset]::Now.AddSeconds([double]$resp.expires_in).ToUnixTimeMilliseconds()

    # Update in memory
    $state.Creds.accessToken = $resp.access_token
    if ($resp.refresh_token) { $state.Creds.refreshToken = $resp.refresh_token }
    if ($state.Creds.PSObject.Properties['expiresAt']) { $state.Creds.expiresAt = $newExpiresAt }
    else { $state.Creds | Add-Member -NotePropertyName expiresAt -NotePropertyValue $newExpiresAt -Force }

    # Persist back to the credentials file (refresh tokens rotate - saving is essential)
    try {
        $json = $state.Raw | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($state.Path, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "Login renewed and saved (valid until $([DateTimeOffset]::FromUnixTimeMilliseconds($newExpiresAt).LocalDateTime))."
    } catch {
        Write-Host "Warning: renewed the login but could not write it back to $($state.Path): $($_.Exception.Message)"
    }
    return $true
}

# ---------------- usage fetch ----------------

function Invoke-UsageApi($accessToken) {
    $headers = @{
        'Authorization'  = "Bearer $accessToken"
        'anthropic-beta' = 'oauth-2025-04-20'
        'User-Agent'     = 'claude-code/2.0.31'
        'Accept'         = 'application/json'
    }
    return Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $headers -Method Get -TimeoutSec 15
}

function Fetch-Usage {
    $now = Get-Date
    if ($script:CachedBody -and ($now - $script:CachedAt).TotalSeconds -lt $CacheSeconds) {
        return $script:CachedBody
    }

    $result = @{}
    try {
        $state = Get-CredentialState

        # Renew proactively if the token is expired or about to expire
        if (Test-TokenExpiringSoon $state.Creds) { [void](Invoke-TokenRefresh $state) }

        $resp = $null
        try {
            $resp = Invoke-UsageApi $state.Creds.accessToken
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -eq 401) {
                # Token rejected -> try one refresh, then retry once
                if (Invoke-TokenRefresh $state) {
                    $resp = Invoke-UsageApi $state.Creds.accessToken
                } else {
                    $result['ok'] = $false
                    $result['error'] = 'The saved login could not be renewed. Run ''claude'' in a terminal and log in once - after that, renewal is automatic.'
                }
            } else {
                $result['ok'] = $false
                $result['error'] = "Could not reach Anthropic ($($_.Exception.Message))"
            }
        }

        if ($resp) {
            $resp.PSObject.Properties | ForEach-Object { $result[$_.Name] = $_.Value }
            $result['ok'] = $true
        }
        if ($state.Creds.subscriptionType) { $result['subscription'] = $state.Creds.subscriptionType }
    } catch {
        $result['ok'] = $false
        $result['error'] = $_.Exception.Message
    }

    $result['fetched_at'] = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

    $body = ($result | ConvertTo-Json -Depth 10)
    if ($result['ok']) {
        $script:CachedBody = $body
        $script:CachedAt   = $now
    } else {
        $script:CachedBody = $null
    }
    return $body
}

# ---------------- HTTP server ----------------

function Send-Response {
    param($Stream, [int]$Code, [string]$ContentType, [byte[]]$Bytes)
    $statusText = switch ($Code) { 200 {'OK'} 404 {'Not Found'} default {'Error'} }
    $headerStr = "HTTP/1.1 $Code $statusText`r`n" +
                 "Content-Type: $ContentType`r`n" +
                 "Content-Length: $($Bytes.Length)`r`n" +
                 "Access-Control-Allow-Origin: *`r`n" +
                 "Cache-Control: no-store`r`n" +
                 "Connection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerStr)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
} catch {
    Write-Host "Port $Port is already in use. Is the server already running?"
    exit 1
}
Write-Host "Claude usage helper listening on http://127.0.0.1:$Port/  (Ctrl+C to stop)"

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)

        $requestLine = $reader.ReadLine()
        if (-not $requestLine) { $client.Close(); continue }
        while (($line = $reader.ReadLine()) -and $line -ne '') { }

        $parts = $requestLine -split ' '
        $path = if ($parts.Length -ge 2) { $parts[1].Split('?')[0] } else { '/' }

        switch -Regex ($path) {
            '^/usage/?$' {
                $body = Fetch-Usage
                Send-Response $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($body))
            }
            '^/health/?$' {
                Send-Response $stream 200 'text/plain' ([Text.Encoding]::UTF8.GetBytes('ok'))
            }
            '^/(index\.html)?$' {
                $htmlPath = Join-Path $PSScriptRoot 'index.html'
                if (Test-Path $htmlPath) {
                    Send-Response $stream 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($htmlPath))
                } else {
                    Send-Response $stream 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('index.html not found next to the server script'))
                }
            }
            default {
                Send-Response $stream 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found'))
            }
        }
    } catch {
        # Ignore per-connection errors; keep serving
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
