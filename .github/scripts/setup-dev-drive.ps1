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

    $linker = $null
    $rustc = Get-Command rustc -ErrorAction SilentlyContinue
    if ($rustc) {
        $sysroot = (& rustc --print sysroot 2>$null).Trim()
        if ($sysroot) {
            $rustLld = Join-Path $sysroot "lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe"
            if (Test-Path $rustLld) {
                $linker = $rustLld
            }
        }
    }
    if (-not $linker) {
        $linker = Join-Path $installPath "VC\Tools\Llvm\x64\bin\lld-link.exe"
    }
    if (-not (Test-Path $linker)) {
        $linker = Join-Path $vcToolsInstallDir "bin\HostX64\$TargetArch\link.exe"
    }
    if (-not (Test-Path $linker)) {
        throw "Windows linker not found at $linker"
    }

    if ((Split-Path -Leaf $linker) -match "lld") {
        $wrapperDir = Join-Path $env:RUNNER_TEMP "arm64-archive-lld-wrapper"
        New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null
        $wrapperPath = Join-Path $wrapperDir "lld-link-wrapper.exe"
        $wrapperSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Program
{
    private static int Main(string[] args)
    {
        var linker = Environment.GetEnvironmentVariable("ARM64_ARCHIVE_REAL_LINKER");
        if (string.IsNullOrEmpty(linker))
        {
            Console.Error.WriteLine("ARM64_ARCHIVE_REAL_LINKER is not set");
            return 1;
        }

        var startInfo = new ProcessStartInfo(linker)
        {
            UseShellExecute = false,
        };
        var filteredArgs = new List<string> { "-flavor", "link", "/defaultlib:ucrt", "/nodefaultlib:libucrt" };
        foreach (var arg in args)
        {
            if (!string.Equals(arg, "/arm64hazardfree", StringComparison.OrdinalIgnoreCase))
            {
                filteredArgs.Add(QuoteArgument(FilterResponseFile(arg)));
            }
        }
        startInfo.Arguments = string.Join(" ", filteredArgs);

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            Console.Error.WriteLine($"Failed to start linker: {linker}");
            return 1;
        }

        process.WaitForExit();
        return process.ExitCode;
    }

    private static string FilterResponseFile(string argument)
    {
        if (argument.Length < 2 || argument[0] != '@')
        {
            return argument;
        }

        var responsePath = argument.Substring(1);
        if (!File.Exists(responsePath))
        {
            return argument;
        }

        var filteredResponsePath = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName() + ".rsp");
        var responseContents = File.ReadAllText(responsePath).Replace("/arm64hazardfree", string.Empty);
        File.WriteAllText(filteredResponsePath, responseContents);
        return "@" + filteredResponsePath;
    }

    private static string QuoteArgument(string argument)
    {
        if (argument.Length == 0)
        {
            return "\"\"";
        }
        if (argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return argument;
        }

        var quoted = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', (backslashes * 2) + 1);
                quoted.Append(character);
                backslashes = 0;
                continue;
            }

            quoted.Append('\\', backslashes);
            backslashes = 0;
            quoted.Append(character);
        }
        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }
}
'@
        $wrapperSourcePath = Join-Path $wrapperDir "lld-link-wrapper.cs"
        $wrapperSource | Out-File -FilePath $wrapperSourcePath -Encoding utf8
        $csc = Join-Path $installPath "MSBuild\Current\Bin\Roslyn\csc.exe"
        if (-not (Test-Path $csc)) {
            throw "csc.exe not found at $csc"
        }
        & $csc /nologo /target:exe /out:$wrapperPath $wrapperSourcePath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to compile lld-link wrapper"
        }
        "ARM64_ARCHIVE_REAL_LINKER=$linker" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        $linker = $wrapperPath
    }

    Write-Output "Using Windows linker: $linker"
    "CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER=$linker" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

function Install-ArchiveCargoProbe {
    $probeDir = Join-Path $env:RUNNER_TEMP "arm64-archive-cargo-probe"
    New-Item -Path $probeDir -ItemType Directory -Force | Out-Null

    $wrapperPath = Join-Path $probeDir "cargo"
    @'
#!/usr/bin/env bash
exec pwsh -NoProfile -File "$RUNNER_TEMP/arm64-archive-cargo-probe/cargo-wrapper.ps1" "$@"
'@ | Out-File -FilePath $wrapperPath -Encoding utf8

    $wrapperScript = Join-Path $probeDir "cargo-wrapper.ps1"
    @'
$ErrorActionPreference = "Stop"

function Write-ProcessSnapshot {
    $timestamp = Get-Date -Format o
    Write-Output "ARM64_ARCHIVE_PROCESS_SNAPSHOT $timestamp"
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match '^(cargo|rustc|link|sccache|conhost)\.exe$' -or
            $_.CommandLine -match 'cargo nextest archive|codex-cloud-tasks|aarch64-pc-windows-msvc'
        } |
        Sort-Object ProcessId |
        ForEach-Object {
            $commandLine = ($_.CommandLine -replace '\s+', ' ').Trim()
            Write-Output ("ARM64_ARCHIVE_PROCESS pid={0} ppid={1} name={2} cmd={3}" -f $_.ProcessId, $_.ParentProcessId, $_.Name, $commandLine)
        }
}

$realCargo = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
if (-not (Test-Path $realCargo)) {
    throw "cargo.exe not found at $realCargo"
}

$cargo = Start-Process -FilePath $realCargo -ArgumentList $args -NoNewWindow -PassThru
$lastSnapshot = [DateTime]::MinValue
while (-not $cargo.HasExited) {
    if ((Get-Date) - $lastSnapshot -ge [TimeSpan]::FromSeconds(30)) {
        Write-ProcessSnapshot
        $lastSnapshot = Get-Date
    }
    Start-Sleep -Seconds 5
    $cargo.Refresh()
}

exit $cargo.ExitCode
'@ | Out-File -FilePath $wrapperScript -Encoding utf8

    $probeDir | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
}

function Initialize-ArchiveExtractDirectories {
    $partitionCount = 4
    if ($env:NEXTEST_PARTITION -match "^[^:]+:\d+/(\d+)$") {
        $partitionCount = [int]$matches[1]
    }

    foreach ($part in 1..$partitionCount) {
        $directoryName = "nextest-extract-part-{0}-of-{1}" -f $part, $partitionCount
        $directoryPath = Join-Path $env:RUNNER_TEMP $directoryName
        New-Item -Path $directoryPath -ItemType Directory -Force | Out-Null
    }
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
    Initialize-ArchiveExtractDirectories
    Install-ArchiveCargoProbe
}
