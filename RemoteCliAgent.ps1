[CmdletBinding()]
param(
    [ValidateSet('127.0.0.1', '::1')]
    [string]$BindAddress = '127.0.0.1',

    [ValidateRange(1, 65535)]
    [int]$Port = 8787,

    [ValidateRange(1024, 10485760)]
    [int]$MaxBodyBytes = 1048576
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultPrompt = 'You are a local Copilot CLI session. Briefly confirm that you are ready to help with the next task.'
$ResumePrompt = 'Summarize this session in ~50 words'
$SessionStorePath = Join-Path $PSScriptRoot 'session.json'
$CopilotCommand = Get-Command -Name copilot -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -in @('Application', 'ExternalScript') } |
    Select-Object -First 1

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0:O}] {1}' -f (Get-Date), $Message)
}

function New-ErrorResponse {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    [pscustomobject]@{
        StatusCode = $StatusCode
        Body       = @{ error = @{ code = $Code; message = $Message } }
    }
}

function Set-CorsHeaders {
    param([Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response)

    $Response.Headers['Access-Control-Allow-Origin'] = '*'
    $Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    $Response.Headers['Access-Control-Max-Age'] = '86400'
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)]$Body
    )

    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Set-CorsHeaders -Response $Response
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length

    try {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $Response.Close()
    }
}

function Read-JsonRequestBody {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request,
        [Parameter(Mandatory)][int]$MaximumBytes
    )

    if (-not $Request.HasEntityBody -or $Request.ContentLength64 -eq 0) {
        return (New-ErrorResponse -StatusCode 400 -Code 'empty_body' -Message 'A JSON request body is required.')
    }

    if ($Request.ContentLength64 -gt $MaximumBytes) {
        return (New-ErrorResponse -StatusCode 413 -Code 'body_too_large' -Message "Request body exceeds the $MaximumBytes byte limit.")
    }

    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192

    try {
        while (($read = $Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $read)
            if ($memory.Length -gt $MaximumBytes) {
                return (New-ErrorResponse -StatusCode 413 -Code 'body_too_large' -Message "Request body exceeds the $MaximumBytes byte limit.")
            }
        }

        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $utf8.GetString($memory.ToArray())
            $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return (New-ErrorResponse -StatusCode 400 -Code 'invalid_json' -Message 'Request body must contain a UTF-8 JSON object.')
        }

        if ($null -eq $parsed -or $parsed -is [array] -or $parsed -isnot [pscustomobject]) {
            return (New-ErrorResponse -StatusCode 400 -Code 'invalid_json' -Message 'Request body must be a JSON object.')
        }

        return [pscustomobject]@{ StatusCode = 200; Body = $parsed }
    }
    finally {
        $memory.Dispose()
    }
}

function Get-StringProperty {
    param(
        [Parameter(Mandatory)][pscustomobject]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Required
    )

    $property = $Body.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        if ($Required) {
            throw "Missing required '$Name' string."
        }
        return $null
    }

    if ($property.Value -isnot [string]) {
        throw "'$Name' must be a string."
    }

    $value = $property.Value.Trim()
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "'$Name' must not be empty."
    }

    return $value
}

function Get-SavedSessions {
    if (-not (Test-Path -LiteralPath $SessionStorePath -PathType Leaf)) {
        return @()
    }

    try {
        $store = Get-Content -LiteralPath $SessionStorePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $sessions = $store.PSObject.Properties['sessions']
        if ($null -eq $sessions -or $sessions.Value -isnot [array]) {
            throw 'session.json must contain a sessions array.'
        }

        return @($sessions.Value)
    }
    catch {
        throw "Unable to read session.json: $($_.Exception.Message)"
    }
}

function Add-SavedSession {
    param([Parameter(Mandatory)][string]$SessionId)

    $record = [pscustomobject]@{
        sessionId = $SessionId
        createdAt = [DateTime]::UtcNow.ToString('O')
    }
    $existingSessions = @(Get-SavedSessions)
    $store = [pscustomobject]@{ sessions = @($existingSessions; $record) }
    $json = $store | ConvertTo-Json -Depth 3
    $temporaryPath = "$SessionStorePath.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $SessionStorePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Test-SavedSession {
    param([Parameter(Mandatory)][string]$SessionId)

    foreach ($record in @(Get-SavedSessions)) {
        $savedSessionId = $record.PSObject.Properties['sessionId']
        if ($null -ne $savedSessionId -and $savedSessionId.Value -eq $SessionId) {
            return $true
        }
    }

    return $false
}

function Invoke-CopilotPrompt {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Prompt
    )

    if ($null -eq $script:CopilotCommand) {
        throw 'The copilot executable was not found on PATH.'
    }

    $arguments = @('--session-id', $SessionId, '--prompt', $Prompt, '--yolo', '--allow-all-tools', '--silent')
    try {
        # Call the resolved executable with an argument array; request values are never parsed as a command string.
        $output = & $script:CopilotCommand.Source @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        throw "Unable to start copilot: $($_.Exception.Message)"
    }

    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    if ($exitCode -ne 0) {
        throw "Copilot CLI exited with code $exitCode."
    }

    return (($output | Out-String).Trim())
}

function Handle-Request {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)

    if ($Request.HttpMethod -eq 'OPTIONS') {
        return [pscustomobject]@{ StatusCode = 200; Body = @{} }
    }

    $path = $Request.Url.AbsolutePath.TrimEnd('/')
    if ($Request.HttpMethod -eq 'GET' -and $path -eq '/sessions') {
        try {
            return [pscustomobject]@{ StatusCode = 200; Body = @{ sessions = @(Get-SavedSessions) } }
        }
        catch {
            Write-Log "Session store error: $($_.Exception.Message)"
            return (New-ErrorResponse -StatusCode 500 -Code 'session_store_error' -Message 'Unable to access session.json.')
        }
    }

    if ($Request.HttpMethod -ne 'POST') {
        return (New-ErrorResponse -StatusCode 405 -Code 'method_not_allowed' -Message 'Only GET /sessions and POST requests are supported.')
    }

    if ($path -notin @('/new-session', '/chat', '/resume-session')) {
        return (New-ErrorResponse -StatusCode 404 -Code 'not_found' -Message 'Unknown endpoint.')
    }

    if ([string]::IsNullOrWhiteSpace($Request.ContentType) -or
        $Request.ContentType -notmatch '^\s*application/json(?:\s*;|$)') {
        return (New-ErrorResponse -StatusCode 415 -Code 'unsupported_media_type' -Message 'Content-Type must be application/json.')
    }

    $requestBody = Read-JsonRequestBody -Request $Request -MaximumBytes $MaxBodyBytes
    if ($requestBody.StatusCode -ne 200) {
        return $requestBody
    }

    try {
        if ($path -eq '/new-session') {
            $prompt = Get-StringProperty -Body $requestBody.Body -Name 'prompt' -Required $false
            if ([string]::IsNullOrWhiteSpace($prompt)) {
                $prompt = $DefaultPrompt
            }

            $sessionId = [guid]::NewGuid().ToString()
        }
        else {
            $providedSessionId = Get-StringProperty -Body $requestBody.Body -Name 'sessionId' -Required $true
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($providedSessionId, [ref]$guid)) {
                return (New-ErrorResponse -StatusCode 400 -Code 'invalid_session_id' -Message 'sessionId must be a valid GUID.')
            }

            $sessionId = $guid.ToString()
            if ($path -eq '/chat') {
                $prompt = Get-StringProperty -Body $requestBody.Body -Name 'prompt' -Required $true
            }
        }
    }
    catch {
        return (New-ErrorResponse -StatusCode 400 -Code 'invalid_request' -Message $_.Exception.Message)
    }

    try {
        if ($path -eq '/new-session') {
            Add-SavedSession -SessionId $sessionId
        }
        elseif ($path -eq '/resume-session') {
            if (-not (Test-SavedSession -SessionId $sessionId)) {
                return (New-ErrorResponse -StatusCode 404 -Code 'session_not_found' -Message 'sessionId was not found in session.json.')
            }

            $prompt = $ResumePrompt
        }
    }
    catch {
        Write-Log "Session store error: $($_.Exception.Message)"
        return (New-ErrorResponse -StatusCode 500 -Code 'session_store_error' -Message 'Unable to access session.json.')
    }

    try {
        $response = Invoke-CopilotPrompt -SessionId $sessionId -Prompt $prompt
        return [pscustomobject]@{
            StatusCode = 200
            Body       = @{ sessionId = $sessionId; response = $response }
        }
    }
    catch {
        Write-Log "Request failed: $($_.Exception.Message)"
        return (New-ErrorResponse -StatusCode 500 -Code 'copilot_error' -Message $_.Exception.Message)
    }
}

$prefix = if ($BindAddress -eq '::1') { "http://[::1]:$Port/" } else { "http://$BindAddress`:$Port/" }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
    Write-Log "Remote CLI agent listening only on $prefix"
    if ($null -eq $CopilotCommand) {
        Write-Log 'WARNING: copilot executable was not found on PATH; valid endpoint requests will return JSON errors.'
    }
    else {
        Write-Log "Using copilot command: $($CopilotCommand.Source)"
    }
    Write-Log 'Press Ctrl+C to stop.'

    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            break
        }
        catch {
            if ($listener.IsListening) {
                Write-Log "Listener error: $($_.Exception.Message)"
            }
            continue
        }

        $request = $context.Request
        Write-Log "$($request.RemoteEndPoint) $($request.HttpMethod) $($request.Url.AbsolutePath)"
        try {
            $result = Handle-Request -Request $request
            Send-JsonResponse -Response $context.Response -StatusCode $result.StatusCode -Body $result.Body
        }
        catch {
            Write-Log "Unhandled request error: $($_.Exception.Message)"
            try {
                Send-JsonResponse -Response $context.Response -StatusCode 500 -Body @{ error = @{ code = 'internal_error'; message = 'Internal server error.' } }
            }
            catch {
                # The caller may have disconnected before the error response could be written.
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Log 'Remote CLI agent stopped.'
}
