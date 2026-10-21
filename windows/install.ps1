# Whisp for Windows installer — downloads the source, builds it, and installs the app.
#
#   irm https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/windows/install.ps1 | iex
#
# What it does: downloads the latest release of this repo (or main, if no release has
# Windows support yet), builds Whisp with the .NET 8 SDK — installing a private copy
# under %LOCALAPPDATA%\Whisp\dotnet if you don't have one — installs it to
# %LOCALAPPDATA%\Programs\Whisp, adds a Start menu shortcut and an Apps entry for
# uninstalling, and starts it. No administrator rights needed. Running it again
# updates Whisp and keeps your settings, history and words.
#
# WHISP_SRC=<path> builds an existing checkout instead of downloading (development).

function Install-Whisp {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $repo = 'bisheshabramhacharya/whisp'
    $home_ = Join-Path $env:LOCALAPPDATA 'Whisp'
    $installDir = Join-Path $env:LOCALAPPDATA 'Programs\Whisp'

    Write-Host '==> Whisp installer'
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Whisp for Windows needs 64-bit Windows 10 or 11 on an x64 (Intel or AMD) PC.'
    }
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'Whisp needs Windows 10 or 11.'
    }
    New-Item -ItemType Directory -Force $home_ | Out-Null

    # 1. Source
    if ($env:WHISP_SRC) {
        $src = (Resolve-Path $env:WHISP_SRC).Path
        Write-Host "==> building $src"
    } else {
        $src = Join-Path $home_ 'src'
        $refs = @()
        try {
            $tags = Invoke-RestMethod "https://api.github.com/repos/$repo/tags?per_page=20" -Headers @{ 'User-Agent' = 'whisp-install' }
            $refs += $tags | Where-Object { $_.name -match '^v\d' } | Select-Object -First 1 | ForEach-Object { "tags/$($_.name)" }
        } catch {
            Write-Host '    (could not list releases; using main)'
        }
        $refs += 'heads/main'
        $found = $false
        foreach ($ref in $refs) {
            Write-Host "==> downloading $repo@$($ref -replace '^(tags|heads)/', '')"
            $zip = Join-Path $env:TEMP "whisp-src-$([guid]::NewGuid().ToString('N')).zip"
            $unpack = "$zip.d"
            Invoke-WebRequest "https://github.com/$repo/archive/refs/$ref.zip" -OutFile $zip -UseBasicParsing
            Expand-Archive $zip -DestinationPath $unpack -Force
            Remove-Item $zip
            $root = Get-ChildItem $unpack -Directory | Select-Object -First 1
            if (Test-Path (Join-Path $root.FullName 'windows\Whisp\Whisp.csproj')) {
                if (Test-Path $src) { Remove-Item $src -Recurse -Force }
                Move-Item $root.FullName $src
                Remove-Item $unpack -Recurse -Force
                $found = $true
                break
            }
            Remove-Item $unpack -Recurse -Force
            Write-Host '    (that release predates Windows support)'
        }
        if (-not $found) { throw 'No Windows version of Whisp found to build.' }
    }

    # 2. .NET 8 SDK: use one already installed, else a private copy (no admin needed).
    $dotnet = $null
    $system = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($system) {
        $sdks = & $system.Source --list-sdks 2>$null
        if ($sdks | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 8 }) { $dotnet = $system.Source }
    }
    $private = Join-Path $home_ 'dotnet\dotnet.exe'
    if (-not $dotnet -and (Test-Path $private)) { $dotnet = $private }
    if (-not $dotnet) {
        Write-Host '==> installing the .NET 8 SDK (private copy, about 250 MB)'
        $script = Join-Path $env:TEMP 'dotnet-install.ps1'
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $script -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Channel 8.0 -InstallDir (Split-Path $private) -NoPath | Out-Null
        Remove-Item $script
        if (-not (Test-Path $private)) { throw '.NET SDK install failed.' }
        $dotnet = $private
    }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'

    # 3. Build into a staging folder, then swap it in.
    Write-Host '==> building (the first build takes a minute or two)'
    $stage = Join-Path $home_ 'build-stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    & $dotnet publish (Join-Path $src 'windows\Whisp\Whisp.csproj') -c Release -r win-x64 --self-contained true -o $stage --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)." }

    Get-Process Whisp -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$installDir*" } | ForEach-Object {
        Write-Host '==> stopping the running Whisp'
        $_.CloseMainWindow() | Out-Null
        $_ | Stop-Process -Force
        $_.WaitForExit(5000) | Out-Null
    }
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $installDir) | Out-Null
    Move-Item $stage $installDir
    Copy-Item (Join-Path $src 'windows\uninstall.ps1') $installDir
    $exe = Join-Path $installDir 'Whisp.exe'

    # 4. Start menu shortcut and an Apps & features entry.
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Whisp.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $installDir
    $lnk.Description = 'Hold Right Alt, talk, let go.'
    $lnk.Save()

    $version = (Get-Item $exe).VersionInfo.ProductVersion -replace '\+.*$', ''
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Whisp'
    New-Item -Force $uninstallKey | Out-Null
    $values = @{
        DisplayName = 'Whisp'; DisplayVersion = $version; Publisher = 'Whisp (open source)'
        DisplayIcon = $exe; InstallLocation = $installDir; URLInfoAbout = "https://github.com/$repo"
        UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`""
    }
    foreach ($k in $values.Keys) { Set-ItemProperty $uninstallKey -Name $k -Value $values[$k] }
    Set-ItemProperty $uninstallKey -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty $uninstallKey -Name NoRepair -Value 1 -Type DWord

    Write-Host "==> installed Whisp $version to $installDir"
    Start-Process $exe
    Write-Host '==> Whisp is running — look for its icon by the clock. Hold Right Alt and talk.'
}

Install-Whisp
