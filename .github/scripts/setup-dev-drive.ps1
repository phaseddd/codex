# Configure a fast drive for Windows CI jobs.
#
# GitHub-hosted Windows runners do not always expose a secondary D: volume. When
# they do not, try to create a Dev Drive VHD and fall back to C: if the runner
# image does not allow that provisioning path.

function Use-FallbackDrive {
    param([string]$Reason)

    Write-Warning "$Reason Falling back to C:"
    return "C:"
}

function Invoke-BestEffort {
    param([scriptblock]$Script, [string]$Description)

    try {
        & $Script
    } catch {
        Write-Warning "$Description failed: $($_.Exception.Message)"
    }
}

function Export-MsvcEnvironment {
    param(
        [string]$TargetArch,
        [string]$RequiredComponent
    )

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found"
    }

    $installPath = & $vswhere -latest -products * -requires $RequiredComponent -property installationPath 2>$null
    if (-not $installPath) {
        throw "Could not locate a Visual Studio installation with component $RequiredComponent"
    }

    $vsDevCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        throw "VsDevCmd.bat not found at $vsDevCmd"
    }

    $varsToExport = @(
        "INCLUDE",
        "LIB",
        "LIBPATH",
        "PATH",
        "UCRTVersion",
        "UniversalCRTSdkDir",
        "VCINSTALLDIR",
        "VCToolsInstallDir",
        "WindowsLibPath",
        "WindowsSdkBinPath",
        "WindowsSdkDir",
        "WindowsSDKLibVersion",
        "WindowsSDKVersion"
    )
    $envLines = & cmd.exe /c ('"{0}" -no_logo -arch={1} -host_arch=x64 >nul && set' -f $vsDevCmd, $TargetArch)
    $vcToolsInstallDir = $null
    foreach ($line in $envLines) {
        if ($line -notmatch "^(.*?)=(.*)$") {
            continue
        }

        $name = $matches[1]
        $value = $matches[2]
        if ($varsToExport -contains $name) {
            if ($name -ieq "Path") {
                $name = "PATH"
            }
            if ($name -eq "VCToolsInstallDir") {
                $vcToolsInstallDir = $value
            }
            "$name=$value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        }
    }

    if (-not $vcToolsInstallDir) {
        throw "VCToolsInstallDir was not exported by VsDevCmd.bat"
    }

    $linker = Join-Path $vcToolsInstallDir "bin\HostX64\$TargetArch\link.exe"
    if (-not (Test-Path $linker)) {
        throw "MSVC linker not found at $linker"
    }

    "CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER=$linker" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

if (Test-Path "D:\") {
    Write-Output "Using existing drive at D:"
    $Drive = "D:"
} else {
    try {
        $VhdPath = Join-Path $env:RUNNER_TEMP "codex-dev-drive.vhdx"
        $SizeBytes = 64GB

        if (Test-Path $VhdPath) {
            Remove-Item -Path $VhdPath -Force
        }

        New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Dynamic -ErrorAction Stop | Out-Null
        $Mounted = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
        $Disk = $Mounted | Get-Disk -ErrorAction Stop
        $Disk | Initialize-Disk -PartitionStyle GPT -ErrorAction Stop
        $Partition = $Disk | New-Partition -AssignDriveLetter -UseMaximumSize -ErrorAction Stop
        $Volume = $Partition | Format-Volume -FileSystem ReFS -NewFileSystemLabel "CodexDevDrive" -DevDrive -Confirm:$false -Force -ErrorAction Stop

        $Drive = "$($Volume.DriveLetter):"

        Invoke-BestEffort { fsutil devdrv trust $Drive } "Trusting Dev Drive $Drive"
        Invoke-BestEffort { fsutil devdrv enable /disallowAv } "Disabling AV filter attachment for Dev Drives"
        Invoke-BestEffort { fsutil devdrv query $Drive } "Querying Dev Drive $Drive"

        Write-Output "Using Dev Drive at $Drive"
    } catch {
        $Drive = Use-FallbackDrive "Failed to create Dev Drive: $($_.Exception.Message)"
    }
}

$Tmp = "$Drive\codex-tmp"
New-Item -Path $Tmp -ItemType Directory -Force | Out-Null

@(
    "DEV_DRIVE=$Drive"
    "TMP=$Tmp"
    "TEMP=$Tmp"
) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append

if ($env:WINDOWS_ARM64_ARCHIVE_FILE) {
    Write-Output "Exporting ARM64 MSVC environment for nextest archive build"
    Export-MsvcEnvironment -TargetArch "arm64" -RequiredComponent "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
}
