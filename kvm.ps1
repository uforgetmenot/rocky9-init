param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

if ($null -eq $ExtraArgs) {
    $ExtraArgs = @()
}
else {
    $ExtraArgs = @($ExtraArgs) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Write-Err {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Get-ScriptDir {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

$ScriptDir = Get-ScriptDir
$KvmDir = Join-Path -Path (Join-Path -Path $ScriptDir -ChildPath 'kvm') -ChildPath 'rocky9'
$ComposeFile = Join-Path -Path $KvmDir -ChildPath 'docker-compose.yml'
$IsWindowsHost = $env:OS -eq 'Windows_NT'

function Get-YqCommand {
    $cmd = Get-Command -Name 'yq' -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $bundled = if ($IsWindowsHost) {
        Join-Path -Path $ScriptDir -ChildPath 'assets/tools/yq_windows_amd64.exe'
    }
    else {
        Join-Path -Path $ScriptDir -ChildPath 'assets/tools/yq_linux_amd64'
    }

    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }

    return $null
}

function Get-KvmPortsFromComposeYaml {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Err "error: compose file not found: $Path"
        exit 1
    }

    $lines = Get-Content -LiteralPath $Path

    $ports = New-Object System.Collections.Generic.List[string]

    $inServices = $false
    $servicesIndent = 0
    $inKvm = $false
    $kvmIndent = 0
    $inPorts = $false
    $portsIndent = 0

    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) {
            continue
        }

        $indent = $line.Length - $line.TrimStart().Length

        if (-not $inServices) {
            if ($trim -match '^services\s*:\s*$') {
                $inServices = $true
                $servicesIndent = $indent
            }
            continue
        }

        if ($inServices -and -not $inKvm) {
            if ($indent -le $servicesIndent -and -not ($trim -match '^services\s*:\s*$')) {
                break
            }
            if ($trim -match '^kvm\s*:\s*$' -and $indent -gt $servicesIndent) {
                $inKvm = $true
                $kvmIndent = $indent
            }
            continue
        }

        if ($inKvm -and -not $inPorts) {
            if ($indent -le $kvmIndent -and -not ($trim -match '^kvm\s*:\s*$')) {
                break
            }
            if ($trim -match '^ports\s*:\s*$' -and $indent -gt $kvmIndent) {
                $inPorts = $true
                $portsIndent = $indent
            }
            continue
        }

        if ($inPorts) {
            if ($indent -le $portsIndent) {
                break
            }
            if ($trim -match '^-\s*(.+)$') {
                $value = $Matches[1].Trim()
                $value = $value.Trim('"').Trim("'")
                $ports.Add($value) | Out-Null
            }
        }
    }

    return $ports.ToArray()
}

function Get-ComposeHostPort {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $ComposeFile)) {
        Write-Err "error: compose file not found: $ComposeFile"
        exit 1
    }

    $mapping = $null
    $yqCmd = Get-YqCommand
    if ($yqCmd) {
        try {
            $out = & $yqCmd -r ".services.kvm.ports[$Index]" $ComposeFile 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $mapping = ($out | Select-Object -First 1).Trim()
            }
        }
        catch {
        }
    }

    if (-not $mapping -or $mapping -eq 'null') {
        $ports = Get-KvmPortsFromComposeYaml -Path $ComposeFile
        if ($Index -lt 0 -or $Index -ge $ports.Count) {
            Write-Err "error: could not read .services.kvm.ports[$Index] ($Label) from $ComposeFile"
            exit 1
        }
        $mapping = $ports[$Index]
    }

    $mapping = ($mapping -split '/')[0]
    $parts = $mapping -split ':'

    $hostPort = ''
    if ($parts.Count -eq 3) {
        $hostPort = $parts[1]
    }
    elseif ($parts.Count -eq 2) {
        $hostPort = $parts[0]
    }
    elseif ($parts.Count -eq 1) {
        $hostPort = $parts[0]
    }

    if ($hostPort -notmatch '^\d+$') {
        Write-Err "error: unexpected port mapping format for ${Label}: $mapping"
        exit 1
    }

    return $hostPort
}

function Get-VncPort {
    return Get-ComposeHostPort -Index 2 -Label 'VNC'
}

function Get-SshPort {
    return Get-ComposeHostPort -Index 3 -Label 'SSH'
}

function Ensure-SshConfigHost {
    param(
        [Parameter(Mandatory = $true)][string]$HostAlias,
        [Parameter(Mandatory = $true)][string]$SshPort,
        [Parameter(Mandatory = $true)][string]$SshUser
    )

    $sshDir = Join-Path -Path $HOME -ChildPath '.ssh'
    $sshConfig = Join-Path -Path $sshDir -ChildPath 'config'

    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $sshConfig)) {
        New-Item -ItemType File -Path $sshConfig -Force | Out-Null
    }

    $configText = ''
    try {
        $configText = Get-Content -LiteralPath $sshConfig -Raw
    }
    catch {
        $configText = ''
    }

    $escapedAlias = [regex]::Escape($HostAlias)
    if ($configText -match "(?m)^\s*Host\s+$escapedAlias(\s|$)") {
        return
    }

    $entryLines = @(
        ''
        "Host $HostAlias"
        '  HostName localhost'
        "  Port $SshPort"
        "  User $SshUser"
        '  StrictHostKeyChecking no'
    )
    if (-not $IsWindowsHost) {
        $entryLines += '  UserKnownHostsFile /dev/null'
    }

    $entry = ($entryLines -join [Environment]::NewLine) + [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($sshConfig, $entry, $utf8NoBom)
}

function Select-Command {
    $options = @('start', 'stop', 'status', 'shell', 'logs', 'vnc', 'ssh', 'vscode', 'quit')

    while ($true) {
        Write-Host 'Available commands:'
        for ($i = 0; $i -lt $options.Count; $i++) {
            Write-Host ("{0}) {1}" -f ($i + 1), $options[$i])
        }

        $reply = Read-Host 'Select a command (number or name)'
        if ($null -eq $reply) {
            return $null
        }

        $reply = $reply.Trim()
        if ([string]::IsNullOrWhiteSpace($reply)) {
            Write-Err 'Invalid selection. Try again.'
            continue
        }

        if ($reply -match '^\d+$') {
            $idx = [int]$reply - 1
            if ($idx -ge 0 -and $idx -lt $options.Count) {
                $cmd = $options[$idx]
                if ($cmd -eq 'quit') {
                    return $null
                }
                return $cmd
            }
        }
        else {
            foreach ($opt in $options) {
                if ($reply -eq $opt) {
                    if ($opt -eq 'quit') {
                        return $null
                    }
                    return $opt
                }
            }
        }

        Write-Err 'Invalid selection. Try again.'
    }
}

function Show-Usage {
    Write-Host 'Usage: .\\kvm.ps1 <start|stop|status|shell|logs|vnc|ssh|vscode>'
    Write-Host '  logs: passes extra args to docker compose logs'
    Write-Host '  ssh:  .\\kvm.ps1 ssh [user] [extra ssh args...]'
    Write-Host '  vscode: .\\kvm.ps1 vscode [user] [host-alias] [remote-dir]'
    Write-Host 'Or run without arguments for an interactive menu.'
}

function Invoke-DockerCompose {
    param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)

    $ComposeArgs = @($ComposeArgs) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $ComposeArgs = @($ComposeArgs)
    if ($ComposeArgs.Count -eq 0) {
        Write-Err 'error: internal: docker compose args are empty'
        exit 1
    }

    if (-not (Test-Path -LiteralPath $KvmDir)) {
        Write-Err "error: KVM_DIR not found: $KvmDir"
        exit 1
    }

    Push-Location -LiteralPath $KvmDir
    try {
        & docker compose @ComposeArgs
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        exit $exitCode
    }
}

if (-not $Command) {
    $Command = Select-Command
    if (-not $Command) {
        exit 0
    }
}

switch ($Command) {
    'start' {
        Write-Host 'Starting KVM Rocky9...'
        Invoke-DockerCompose -ComposeArgs @('up', '-d')
    }
    'stop' {
        Write-Host 'Stopping KVM Rocky9...'
        Invoke-DockerCompose -ComposeArgs @('stop')
    }
    'status' {
        Invoke-DockerCompose -ComposeArgs @('ps')
    }
    'shell' {
        Invoke-DockerCompose -ComposeArgs @('exec', 'kvm', '/bin/bash')
    }
    'logs' {
        $composeArgs = @('logs')
        if ($ExtraArgs) {
            $composeArgs += $ExtraArgs
        }
        Invoke-DockerCompose -ComposeArgs $composeArgs
    }
    'vnc' {
        $vncViewerCmd = $null
        $vncViewerBin = $null

        $cmd = Get-Command -Name 'vncviewer' -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $cmd = Get-Command -Name 'tvnviewer' -ErrorAction SilentlyContinue
        }

        if ($cmd) {
            $vncViewerCmd = $cmd.Name
        }
        elseif ($IsWindowsHost) {
            $basePaths = @()
            if ($env:ProgramFiles) {
                $basePaths += $env:ProgramFiles
            }
            if (${env:ProgramFiles(x86)}) {
                $basePaths += ${env:ProgramFiles(x86)}
            }

            $relativePaths = @(
                'TightVNC\tvnviewer.exe',
                'TigerVNC\vncviewer.exe',
                'RealVNC\VNC Viewer\vncviewer.exe'
            )

            $candidates = New-Object System.Collections.Generic.List[string]
            foreach ($basePath in $basePaths) {
                foreach ($relPath in $relativePaths) {
                    $candidates.Add((Join-Path -Path $basePath -ChildPath $relPath)) | Out-Null
                }
            }

            $vncViewerBin = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }

        if (-not $vncViewerCmd -and -not $vncViewerBin) {
            Write-Err "error: VNC viewer not found (install one, add 'vncviewer' to PATH, or install TightVNC/TigerVNC)"
            exit 1
        }

        $vncPort = Get-VncPort
        Write-Host "Connecting to VNC on localhost:$vncPort ..."
        if ($vncViewerCmd) {
            & $vncViewerCmd "localhost::$vncPort"
        }
        else {
            & $vncViewerBin "localhost::$vncPort"
        }
        exit $LASTEXITCODE
    }
    'ssh' {
        if (-not (Get-Command -Name 'ssh' -ErrorAction SilentlyContinue)) {
            Write-Err "error: 'ssh' not found in PATH"
            exit 1
        }

        $sshPort = Get-SshPort
        $sshUser = if ($ExtraArgs.Count -ge 1) { $ExtraArgs[0] } else { 'virtualink' }
        $sshExtra = if ($ExtraArgs.Count -gt 1) { $ExtraArgs[1..($ExtraArgs.Count - 1)] } else { @() }

        $sshCopyIdCmd = "ssh-copy-id -p $sshPort $sshUser@localhost"
        Write-Host "Run to copy your SSH key to the VM: $sshCopyIdCmd"

        Write-Host "Connecting to SSH on localhost:$sshPort as $sshUser ..."
        & ssh -p $sshPort "$sshUser@localhost" @sshExtra
        exit $LASTEXITCODE
    }
    'vscode' {
        if (-not (Get-Command -Name 'code' -ErrorAction SilentlyContinue)) {
            Write-Err "error: VS Code 'code' command not found in PATH"
            exit 1
        }

        $sshPort = Get-SshPort
        $sshUser = if ($ExtraArgs.Count -ge 1) { $ExtraArgs[0] } else { 'virtualink' }
        $hostAlias = if ($ExtraArgs.Count -ge 2) { $ExtraArgs[1] } else { 'localhost' }

        $defaultRemoteDir = if ($sshUser -eq 'root') { '/root/work' } else { "/home/$sshUser/work" }
        $remoteDir = if ($ExtraArgs.Count -ge 3) { $ExtraArgs[2] } else { $defaultRemoteDir }

        Ensure-SshConfigHost -HostAlias $hostAlias -SshPort $sshPort -SshUser $sshUser

        if (-not (Get-Command -Name 'ssh' -ErrorAction SilentlyContinue)) {
            Write-Err "error: 'ssh' not found in PATH (required to ensure remote directory exists: $remoteDir)"
            exit 1
        }

        if ([string]::IsNullOrWhiteSpace($remoteDir)) {
            Write-Err 'error: remoteDir is empty'
            exit 1
        }

        $remoteDirEscaped = $remoteDir -replace "'", "'`"`'`"`'"
        $remoteMkdirCommand = "mkdir -p -- '$remoteDirEscaped'"
        $sshArgs = @('-p', $sshPort, '-o', 'StrictHostKeyChecking=no', "$sshUser@$hostAlias", $remoteMkdirCommand)
        & ssh @sshArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Err "error: failed to ensure remote directory exists: $remoteDir"
            exit $LASTEXITCODE
        }

        Write-Host "Opening VS Code Remote-SSH: ${hostAlias}:$remoteDir with user $sshUser in port $sshPort ..."
        $folderUri = "vscode-remote://ssh-remote+${sshUser}@${hostAlias}:${sshPort}${remoteDir}"
        # Remove-Item -Path ~/.ssh/known_hosts -ErrorAction SilentlyContinue
        & code --folder-uri=$folderUri
        exit $LASTEXITCODE
    }
    Default {
        Show-Usage
        exit 1
    }
}
