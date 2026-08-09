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

# ---------------- local token / cost tracking ----------------
#
# Reads Claude Code's own local session transcripts (~/.claude/projects/**/*.jsonl,
# the same files a tool like ccusage reads) to estimate token usage and cost that
# the OAuth /usage endpoint doesn't report (it only gives utilization percentages).
#
# Cost is an ESTIMATE using Anthropic's published pay-as-you-go API list prices
# applied to your local token counts - it is NOT your actual bill (Claude
# subscriptions are flat-rate). Treat it as "what this usage would cost via the
# API," a useful gauge of how heavy a session was, not a real charge.
#
# Prices are $ per million tokens. Cache write/read are derived from the input
# price using Anthropic's published multipliers (5-min write = 1.25x input,
# 1-hour write = 2x input, cache read = 0.1x input) - confirmed consistent
# across every current model's published pricing.
$script:Pricing = [ordered]@{
    'claude-opus-5'            = @{ In = 5;   Out = 25 }
    'claude-opus-4-8'          = @{ In = 5;   Out = 25 }
    'claude-opus-4-7'          = @{ In = 5;   Out = 25 }
    'claude-opus-4-6'          = @{ In = 5;   Out = 25 }
    'claude-opus-4-5'          = @{ In = 5;   Out = 25 }
    'claude-opus-4-1'          = @{ In = 15;  Out = 75 }
    'claude-opus-4-20250514'   = @{ In = 15;  Out = 75 }
    'claude-sonnet-5'          = @{ In = 2;   Out = 10 }  # introductory price through 2026-08-31, then $3/$15
    'claude-sonnet-4-6'        = @{ In = 3;   Out = 15 }
    'claude-sonnet-4-5'        = @{ In = 3;   Out = 15 }
    'claude-sonnet-4-20250514' = @{ In = 3;   Out = 15 }
    'claude-haiku-4-5'         = @{ In = 1;   Out = 5 }
    'claude-3-5-haiku'         = @{ In = 0.8; Out = 4 }
    'claude-fable-5'           = @{ In = 10;  Out = 50 }
    'claude-mythos-5'          = @{ In = 10;  Out = 50 }
}
$script:PricingKeys = $script:Pricing.Keys | Sort-Object Length -Descending

function Get-ModelPrice($model) {
    if (-not $model) { return $null }
    foreach ($k in $script:PricingKeys) {
        if ($model.StartsWith($k)) { return $script:Pricing[$k] }
    }
    return $null   # unknown/new model - excluded from cost (tokens still counted elsewhere)
}

function Get-EntryCost($usage, $model) {
    $pr = Get-ModelPrice $model
    if (-not $pr) { return 0.0 }
    $inp = [double]$pr.In; $outp = [double]$pr.Out
    $it = 0.0; if ($usage.input_tokens) { $it = [double]$usage.input_tokens }
    $ot = 0.0; if ($usage.output_tokens) { $ot = [double]$usage.output_tokens }
    $cr = 0.0; if ($usage.cache_read_input_tokens) { $cr = [double]$usage.cache_read_input_tokens }
    $c5 = 0.0; $c1 = 0.0
    if ($usage.cache_creation -and ($usage.cache_creation.ephemeral_5m_input_tokens -or $usage.cache_creation.ephemeral_1h_input_tokens)) {
        if ($usage.cache_creation.ephemeral_5m_input_tokens) { $c5 = [double]$usage.cache_creation.ephemeral_5m_input_tokens }
        if ($usage.cache_creation.ephemeral_1h_input_tokens) { $c1 = [double]$usage.cache_creation.ephemeral_1h_input_tokens }
    } elseif ($usage.cache_creation_input_tokens) {
        # No 5m/1h breakdown available - assume the cheaper 5m tier (conservative).
        $c5 = [double]$usage.cache_creation_input_tokens
    }
    return ($it / 1e6) * $inp + ($ot / 1e6) * $outp + ($c5 / 1e6) * (1.25 * $inp) + ($c1 / 1e6) * (2 * $inp) + ($cr / 1e6) * (0.1 * $inp)
}

function Find-ProjectsDir {
    # Mirrors Find-CredentialFile's search locations, but for the "projects"
    # sibling folder where Claude Code keeps session transcripts.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:CLAUDE_CONFIG_DIR) { $candidates.Add((Join-Path $env:CLAUDE_CONFIG_DIR 'projects')) }
    $candidates.Add((Join-Path $env:USERPROFILE '.claude\projects'))
    try {
        $distros = & wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
        foreach ($d in $distros) {
            foreach ($root in @("\\wsl.localhost\$d", "\\wsl$\$d")) {
                $homeBase = Join-Path $root 'home'
                if (Test-Path $homeBase -ErrorAction SilentlyContinue) {
                    Get-ChildItem $homeBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $candidates.Add((Join-Path $_.FullName '.claude\projects'))
                    }
                    $candidates.Add((Join-Path $root 'root\.claude\projects'))
                    break
                }
            }
        }
    } catch { }
    return @($candidates | Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) })
}

function Get-LocalTokenStats($fiveHourResetsAt, $weeklyResetsAt) {
    $now = Get-Date
    $stats = @{ available = $false }

    $dirs = Find-ProjectsDir
    if (-not $dirs -or $dirs.Count -eq 0) { return $stats }

    # Only files touched recently enough to matter for a 7-day window (+ buffer).
    $cutoff = (Get-Date).AddDays(-8)
    $files = @()
    foreach ($d in $dirs) {
        $files += Get-ChildItem -Path $d -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -ge $cutoff }
    }
    if ($files.Count -eq 0) { return $stats }

    # Anchor session/week windows to the OAuth data's own reset times when we
    # have them, so "session" here means the same 5-hour block the ring shows.
    $sessStart = $now.AddHours(-5)
    if ($fiveHourResetsAt) {
        try { $sessStart = ([datetime]$fiveHourResetsAt).ToLocalTime().AddHours(-5) } catch { }
    }
    $weekStart = $now.AddDays(-7)
    if ($weeklyResetsAt) {
        try { $weekStart = ([datetime]$weeklyResetsAt).ToLocalTime().AddDays(-7) } catch { }
    }
    $burnStart = $now.AddMinutes(-30)

    # Dedup by request id: Claude Code sometimes logs more than one JSONL line
    # for the same underlying API call (e.g. streaming + finalization); each
    # real call gets one unique requestId/message.id, so we count it once.
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $sessTok = 0.0; $sessCost = 0.0
    $weekTok = 0.0; $weekCost = 0.0
    $burnTok = 0.0; $burnCost = 0.0
    $burnEarliest = $null; $burnLatest = $null

    foreach ($f in $files) {
        $lines = $null
        try { $lines = [System.IO.File]::ReadAllLines($f.FullName) } catch { continue }
        foreach ($line in $lines) {
            if (-not $line -or $line.IndexOf('"type":"assistant"') -lt 0) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($o.type -ne 'assistant' -or -not $o.usage) { continue }

            $rid = $o.requestId
            if (-not $rid -and $o.message) { $rid = $o.message.id }
            if (-not $rid) { $rid = $o.uuid }
            if (-not $rid) { continue }
            if (-not $seen.Add($rid)) { continue }   # already counted this API call

            $ts = $null
            try { $ts = ([datetime]$o.timestamp).ToLocalTime() } catch { continue }

            $u = $o.usage
            $tok = 0.0
            if ($u.input_tokens) { $tok += [double]$u.input_tokens }
            if ($u.output_tokens) { $tok += [double]$u.output_tokens }
            if ($u.cache_creation_input_tokens) { $tok += [double]$u.cache_creation_input_tokens }
            if ($u.cache_read_input_tokens) { $tok += [double]$u.cache_read_input_tokens }
            $cost = Get-EntryCost $u $o.model

            if ($ts -ge $sessStart) { $sessTok += $tok; $sessCost += $cost }
            if ($ts -ge $weekStart) { $weekTok += $tok; $weekCost += $cost }
            if ($ts -ge $burnStart) {
                $burnTok += $tok; $burnCost += $cost
                if (-not $burnEarliest -or $ts -lt $burnEarliest) { $burnEarliest = $ts }
                if (-not $burnLatest -or $ts -gt $burnLatest) { $burnLatest = $ts }
            }
        }
    }

    $stats['available']     = $true
    $stats['tokensSession'] = [math]::Round($sessTok)
    $stats['tokensWeek']    = [math]::Round($weekTok)
    $stats['costSession']   = [math]::Round($sessCost, 4)
    $stats['costWeek']      = [math]::Round($weekCost, 4)

    # Burn rate / block projection need enough of a time span to be meaningful -
    # a 10-second span would extrapolate wildly, so require at least 2 minutes.
    $spanMin = 0.0
    if ($burnEarliest -and $burnLatest) { $spanMin = ($burnLatest - $burnEarliest).TotalMinutes }
    if ($spanMin -ge 2) {
        $tpm = $burnTok / $spanMin
        $cph = ($burnCost / $spanMin) * 60.0
        $stats['tokensPerMin'] = [math]::Round($tpm, 1)
        $stats['costPerHour']  = [math]::Round($cph, 2)

        if ($fiveHourResetsAt) {
            try {
                $resetLocal = ([datetime]$fiveHourResetsAt).ToLocalTime()
                $minsLeft = ($resetLocal - $now).TotalMinutes
                if ($minsLeft -gt 0) {
                    $stats['blockProjectedTokens'] = [math]::Round($sessTok + $tpm * $minsLeft)
                    $stats['blockProjectedCost']   = [math]::Round($sessCost + ($cph / 60.0) * $minsLeft, 2)
                }
            } catch { }
        }
    }

    return $stats
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

        # Local token/cost stats are a best-effort add-on - never let a problem
        # here take down the usage endpoint the widget actually depends on.
        if ($result['ok']) {
            try {
                $fiveHourResetsAt = $null
                if ($result['five_hour'] -and $result['five_hour'].resets_at) { $fiveHourResetsAt = $result['five_hour'].resets_at }
                $weeklyResetsAt = $null
                if ($result['seven_day'] -and $result['seven_day'].resets_at) { $weeklyResetsAt = $result['seven_day'].resets_at }

                $local = Get-LocalTokenStats $fiveHourResetsAt $weeklyResetsAt
                if ($local['available']) { $result['local'] = $local }
            } catch { }
        }
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
