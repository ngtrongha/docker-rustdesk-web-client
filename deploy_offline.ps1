[CmdletBinding()]
param(
    [string]$ServerIP = '172.16.3.28',
    [string]$ServerUser = 'app-ubuntu',
    [string]$RemotePath = '/home/app-ubuntu/serverpod_app/rustdesk-deploy/web-client',
    [string]$RustDeskRemotePath = '/home/app-ubuntu/serverpod_app/rustdesk-deploy',
    [string]$PublicHost = 'remote-connect.bvkhanhhoa.cloud',
    [string]$ApiServer = 'https://danhba.bvkhanhhoa.cloud',
    [string]$PrivateBindIP = '172.16.3.28',
    [ValidateRange(1, 65535)]
    [int]$PrivateBindPort = 22180,
    [ValidateRange(30, 900)]
    [int]$HealthTimeoutSeconds = 180,
    [switch]$Initialize,
    [switch]$ConfirmClientRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PinnedRustDeskRef = '0b24f1ba9f69b0022d09464c6d24f1c45271f294'
$ExpectedWebDepsSha256 = 'b66011c4fc066b90c46ba0c78884fe5d1a7e5a7fad3dce401300ad893de63818'
$ImageRepository = 'local-rustdesk-web-client'
$ComposeFile = Join-Path $PSScriptRoot 'docker-compose.web.yml'
$RemoteHelper = Join-Path $PSScriptRoot 'scripts/deploy_remote.sh'
$WebDepsArchive = Join-Path $PSScriptRoot 'web_deps.tar.gz'
$Dockerfile = Join-Path $PSScriptRoot 'Dockerfile'
$RootComposeFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'docker-compose.yml'
$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "rustdesk-web-deploy-$PID"
$ImageTar = Join-Path $TemporaryDirectory 'rustdesk-web-image.tar'
$SmokeContainer = "rustdesk-web-smoke-$PID"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-LastExitCode {
    param([string]$Action)
    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)] [string]$Action
    )
    & $FilePath @ArgumentList
    Assert-LastExitCode $Action
}

function Assert-SafeInputs {
    foreach ($Path in @($RemotePath, $RustDeskRemotePath)) {
        if ($Path -notmatch '^/[A-Za-z0-9._/-]+$' -or $Path.Contains('..')) {
            throw "Unsafe remote path: $Path"
        }
    }
    if ($ServerUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        throw 'ServerUser contains unsupported characters.'
    }
    if ($PublicHost -notmatch '^[A-Za-z0-9.-]+$') {
        throw 'PublicHost is not a valid hostname.'
    }
    if ($ApiServer -notmatch '^https://[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[A-Za-z0-9._~/-]*)?$') {
        throw 'ApiServer must be a safe HTTPS URL.'
    }
    $ParsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($ServerIP, [ref]$ParsedAddress)) {
        throw 'ServerIP is not a valid IP address.'
    }
    $ParsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($PrivateBindIP, [ref]$ParsedAddress)) {
        throw 'PrivateBindIP is not a valid IP address.'
    }
}

function Get-GitOutput {
    param([string[]]$Arguments)
    $Output = & git -C $PSScriptRoot @Arguments
    Assert-LastExitCode "git $($Arguments -join ' ')"
    return ($Output | Out-String).Trim()
}

function Wait-ForLocalSmokeHealth {
    param([int]$TimeoutSeconds)
    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Status = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $SmokeContainer 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $Status -eq 'healthy') {
            return
        }
        Start-Sleep -Seconds 2
    }
    & docker logs --tail 100 $SmokeContainer
    throw 'Local Web Client smoke container did not become healthy.'
}

Assert-SafeInputs

Write-Step 'Checking local prerequisites and immutable inputs'
foreach ($Command in @('docker', 'git', 'ssh', 'scp')) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $Command"
    }
}
foreach ($RequiredFile in @($ComposeFile, $RemoteHelper, $WebDepsArchive, $Dockerfile)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "Required file is missing: $RequiredFile"
    }
}

Invoke-External -FilePath docker -ArgumentList @('info') -Action 'Docker daemon check'
Invoke-External -FilePath docker -ArgumentList @('compose', 'version') -Action 'Docker Compose check'

$WorkingTreeStatus = Get-GitOutput @('status', '--porcelain', '--untracked-files=all')
if ($WorkingTreeStatus) {
    throw 'The Web Client repository has uncommitted files. Commit the deployment sources before building an immutable image.'
}

$GitShortSha = Get-GitOutput @('rev-parse', '--short=12', 'HEAD')
$Image = "${ImageRepository}:$GitShortSha"
$ActualWebDepsSha256 = (Get-FileHash -LiteralPath $WebDepsArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualWebDepsSha256 -ne $ExpectedWebDepsSha256) {
    throw "web_deps.tar.gz SHA-256 mismatch. Expected $ExpectedWebDepsSha256, got $ActualWebDepsSha256."
}

$DockerfileText = Get-Content -LiteralPath $Dockerfile -Raw
if (-not $DockerfileText.Contains("ARG RUSTDESK_REF=$PinnedRustDeskRef")) {
    throw 'Dockerfile does not contain the approved pinned RustDesk source commit.'
}
if ($DockerfileText -match 'raw/refs/heads/main/web_deps|wget.+web_deps|curl.+web_deps') {
    throw 'Dockerfile still contains a dynamic web_deps download.'
}
if ($DockerfileText -match "sed[^`n]+ws://[^`n]+wss://") {
    throw 'Dockerfile still contains a global ws:// to wss:// replacement.'
}

if ($Initialize) {
    if (-not (Test-Path -LiteralPath $RootComposeFile -PathType Leaf)) {
        throw "Root RustDesk Compose file is missing: $RootComposeFile"
    }
    $RootComposeText = Get-Content -LiteralPath $RootComposeFile -Raw
    if ($RootComposeText -notmatch 'command:\s*hbbs -k _') {
        throw 'Root Compose has not been changed to the approved hbbs -k _ command.'
    }
}

New-Item -ItemType Directory -Path $TemporaryDirectory -Force | Out-Null

try {
    Write-Step "Building immutable image $Image"
    Invoke-External -FilePath docker -ArgumentList @(
        'build',
        '--build-arg', "RUSTDESK_REF=$PinnedRustDeskRef",
        '--build-arg', "WEB_DEPS_SHA256=$ExpectedWebDepsSha256",
        '--tag', $Image,
        $PSScriptRoot
    ) -Action 'Docker image build'

    Write-Step 'Running local health and runtime-config checks'
    & docker container rm --force $SmokeContainer 2>$null | Out-Null
    & docker run --detach --name $SmokeContainer `
        --env "PUBLIC_HOST=$PublicHost" `
        --env "API_SERVER=$ApiServer" `
        --env "RENDEZVOUS_SERVER=$ServerIP" `
        --env "RELAY_SERVER=$ServerIP" `
        --env 'RUSTDESK_PUBLIC_KEY=LOCAL_SMOKE_TEST_KEY' `
        $Image | Out-Null
    Assert-LastExitCode 'Local smoke container start'

    try {
        Wait-ForLocalSmokeHealth -TimeoutSeconds 90
        $IndexHtml = (& docker exec $SmokeContainer wget -qO- http://127.0.0.1/ | Out-String)
        Assert-LastExitCode 'Local UI HTTP check'
        if (-not $IndexHtml.Contains('/runtime-config.js') -or -not $IndexHtml.Contains('/runtime-config-bootstrap.js')) {
            throw 'Built index.html does not load the runtime configuration before Flutter starts.'
        }
        $RuntimeConfig = (& docker exec $SmokeContainer wget -qO- http://127.0.0.1/runtime-config.js | Out-String)
        Assert-LastExitCode 'Local runtime-config check'
        if (-not $RuntimeConfig.Contains($PublicHost) -or
            -not $RuntimeConfig.Contains($ApiServer) -or
            -not $RuntimeConfig.Contains($ServerIP) -or
            -not $RuntimeConfig.Contains('LOCAL_SMOKE_TEST_KEY')) {
            throw 'Generated runtime-config.js does not contain the requested host and public key.'
        }
        if ($RuntimeConfig -match '(?i)password|passwd') {
            throw 'Generated runtime-config.js unexpectedly contains a password field.'
        }
        $WebSocketBundle = (& docker exec $SmokeContainer cat /usr/share/nginx/html/js/dist/index.js | Out-String)
        Assert-LastExitCode 'Same-origin WebSocket bundle check'
        if (-not $WebSocketBundle.Contains('/ws/id') -or -not $WebSocketBundle.Contains('/ws/relay')) {
            throw 'Built JavaScript bundle does not contain both same-origin WebSocket paths.'
        }
        if ($WebSocketBundle -match 'wss?://[^"'']+:2111(?:8|9)') {
            throw 'Built JavaScript bundle still contains a direct WebSocket port.'
        }
    }
    finally {
        & docker container rm --force $SmokeContainer 2>$null | Out-Null
    }

    Write-Step 'Packing and uploading the offline deployment bundle'
    Invoke-External -FilePath docker -ArgumentList @('save', '--output', $ImageTar, $Image) -Action 'Docker image export'

    $Target = "$ServerUser@$ServerIP"
    $IncomingPath = "$RemotePath/.incoming"
    Invoke-External -FilePath ssh -ArgumentList @($Target, 'mkdir', '-p', '--', $IncomingPath) -Action 'Remote directory creation'
    Invoke-External -FilePath scp -ArgumentList @($ImageTar, "${Target}:$IncomingPath/rustdesk-web-image.tar") -Action 'Image upload'
    Invoke-External -FilePath scp -ArgumentList @($ComposeFile, "${Target}:$IncomingPath/docker-compose.web.yml") -Action 'Web Compose upload'
    Invoke-External -FilePath scp -ArgumentList @($RemoteHelper, "${Target}:$IncomingPath/deploy_remote.sh") -Action 'Remote helper upload'
    if ($Initialize) {
        Invoke-External -FilePath scp -ArgumentList @($RootComposeFile, "${Target}:$IncomingPath/docker-compose.root.yml") -Action 'hbbs Compose upload'
    }

    Write-Step 'Deploying only the isolated rustdesk-web service'
    Invoke-External -FilePath ssh -ArgumentList @(
        $Target,
        'bash', "$IncomingPath/deploy_remote.sh",
        'deploy', $RemotePath, $RustDeskRemotePath, $Image, $PublicHost, $ApiServer,
        $PrivateBindIP, $PrivateBindPort.ToString(), $HealthTimeoutSeconds.ToString(),
        $Initialize.IsPresent.ToString().ToLowerInvariant()
    ) -Action 'Remote Web Client deployment'

    if ($Initialize) {
        $InitializationCommitted = $false
        try {
            $RegistrationConfirmed = $ConfirmClientRegistration.IsPresent
            if (-not $RegistrationConfirmed) {
                Write-Host ''
                Write-Host 'hbbs has been recreated and is stable. Test one LAN client now.' -ForegroundColor Yellow
                $Answer = Read-Host 'Type YES only after the client has registered again; any other answer rolls hbbs back'
                $RegistrationConfirmed = $Answer -ceq 'YES'
            }
            if (-not $RegistrationConfirmed) {
                throw 'LAN client registration was not confirmed.'
            }

            Invoke-External -FilePath ssh -ArgumentList @(
                $Target, 'bash', "$IncomingPath/deploy_remote.sh",
                'confirm-initialize', $RustDeskRemotePath
            ) -Action 'hbbs initialization confirmation'
            $InitializationCommitted = $true
        }
        finally {
            if (-not $InitializationCommitted) {
                & ssh $Target bash "$IncomingPath/deploy_remote.sh" `
                    rollback-initialize $RustDeskRemotePath $HealthTimeoutSeconds.ToString()
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Automatic hbbs rollback could not be confirmed. The backup is $RustDeskRemotePath/docker-compose.yml.pre-web-init."
                }
            }
        }
    }

    Write-Host "`nDeployment completed: http://${PrivateBindIP}:$PrivateBindPort" -ForegroundColor Green
    Write-Host "Image: $Image" -ForegroundColor Green
}
finally {
    & docker container rm --force $SmokeContainer 2>$null | Out-Null
    if (Test-Path -LiteralPath $TemporaryDirectory) {
        Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force
    }
}
