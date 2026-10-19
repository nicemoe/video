$ErrorActionPreference = 'Stop'
$token = Read-Host 'Paste GitHub token (input is hidden)' -AsSecureString
try {
    if ($token.Length -eq 0) { throw 'Token must not be empty.' }
    $credentialDirectory = Join-Path $env:LOCALAPPDATA 'CodexVideo'
    New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null
    $credentialFile = Join-Path $credentialDirectory 'github-token.dpapi'
    $token | ConvertFrom-SecureString | Set-Content -LiteralPath $credentialFile -Encoding ASCII
    Write-Host 'Token saved encrypted for this Windows user. Tell Codex: token saved.'
} finally {
    $token.Dispose()
}
