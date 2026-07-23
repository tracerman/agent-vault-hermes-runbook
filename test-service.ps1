# Verify a broker service rule BEFORE swapping any real credential.
#
# Sends your placeholder through the broker, then repeats with a deliberately
# unconfigured one. Comparing the two is the whole point: a single result tells
# you nothing, because a working call and a passthrough call can look alike.
#
# Usage:
#   .\test-service.ps1 -Url <url> -Header <name> -Placeholder <string> [-Method POST] [-Body '{}']
#
# Examples:
#   .\test-service.ps1 -Url https://api.exa.ai/search -Header x-api-key `
#       -Placeholder __exa_api_key__ -Method POST
#   .\test-service.ps1 -Url https://api.github.com/user -Header Authorization `
#       -Placeholder "Bearer __github_token__"

param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Header,
    [Parameter(Mandatory)][string]$Placeholder,
    [string]$Method = "GET",
    [string]$Body   = "{}",
    [string]$Ca     = ".\agent-vault-ca\mitm-ca.pem",
    [string]$Broker = "agent-vault:14322",
    [string]$Network = "broker-net"
)

$ErrorActionPreference = 'Continue'

if (-not $env:AGENT_VAULT_TOKEN) { throw "Set AGENT_VAULT_TOKEN first." }
if (-not (Test-Path $Ca))        { throw "CA not found at $Ca" }
$CaAbs = (Resolve-Path $Ca).Path -replace '\\','/'

function Probe([string]$Value) {
    $args = @(
        '-s','-o','/dev/null','-m','30','-w','%{http_code}',
        '--proxy', "http://$($env:AGENT_VAULT_TOKEN)@$Broker",
        '--cacert','/ca.pem',
        '-H', "${Header}: $Value"
    )
    if ($Method -ne 'GET') {
        # Body goes through a file, not an inline string. Quoting through
        # PowerShell -> docker run -> curl mangles JSON reliably.
        $tmp = Join-Path $env:TEMP "avbody-$([guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($tmp, $Body, (New-Object System.Text.UTF8Encoding($false)))
        $tmpAbs = $tmp -replace '\\','/'
        $args += @('-X',$Method,'-H','Content-Type: application/json','-d','@/body.json')
        $r = docker run --rm --network $Network -v "${CaAbs}:/ca.pem:ro" -v "${tmpAbs}:/body.json:ro" `
             curlimages/curl:latest @args $Url 2>$null | Select-Object -Last 1
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $r
    }
    docker run --rm --network $Network -v "${CaAbs}:/ca.pem:ro" `
        curlimages/curl:latest @args $Url 2>$null | Select-Object -Last 1
}

Write-Host "url:    $Url"
Write-Host "header: $Header"
Write-Host ""
$Configured = Probe $Placeholder
$Control    = Probe "__definitely_not_configured__"
Write-Host ("  configured ({0}) -> {1}" -f $Placeholder, $Configured)
Write-Host ("  control    (unconfigured) -> {0}" -f $Control)
Write-Host ""

if ($Configured -eq $Control) {
    switch ($Configured) {
        {$_ -in '401','403'} {
            Write-Host "FAIL: rule is not matching." -ForegroundColor Red
            Write-Host "  Check in this order: host pattern, placeholder string"
            Write-Host "  (exact match, case-sensitive), surface (tick exactly one)."
        }
        '502' {
            Write-Host "FAIL: rule matches but the credential name does not resolve." -ForegroundColor Red
            Write-Host "  The service references a credential that is not in the"
            Write-Host "  vault under that exact name."
        }
        default {
            Write-Host "INCONCLUSIVE: this endpoint returns $Configured regardless of auth." -ForegroundColor Yellow
            Write-Host "  Many /v1/models endpoints are unauthenticated. Pick one"
            Write-Host "  that actually requires a credential."
        }
    }
    exit 1
}

Write-Host "PASS: substitution is firing." -ForegroundColor Green
Write-Host "  A non-200 configured result (400/405/422) is fine: the request"
Write-Host "  authenticated and the body was wrong, which is expected here."
