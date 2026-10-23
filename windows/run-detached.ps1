<#
.SYNOPSIS
  Start a build script detached from the current (ssh) session, with keep-awake and a log file.

.DESCRIPTION
  The process is created through WMI (Win32_Process.Create), so it is NOT a member of the ssh session's
  job object and survives the ssh connection dropping. It runs as the calling user, non-interactive,
  no window on anybody's desktop. No scheduled task is created.

  While it runs, the wrapper holds SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED) so idle
  sleep does not interrupt the build (power settings are not changed; closing the lid can still sleep
  the machine - just re-run, the build scripts resume).

  Log:  <Root>\logs\<Name>-<timestamp>.log   (and <Root>\logs\<Name>-latest.txt holds that path)
  Lock: <Root>\logs\<Name>.pid               (refuses to start a second copy while the first is alive)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\run-detached.ps1 -Name inkscape -Script build-inkscape.ps1 -Root C:\olga-build
  powershell -ExecutionPolicy Bypass -File windows\run-detached.ps1 -Name inkscape -Script build-inkscape.ps1 -Root C:\olga-build -ScriptArgs '-Clean'
#>
param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$Script,      # file name in this folder, e.g. build-inkscape.ps1
    [string]$Root = 'C:\olga-build',
    [string]$ScriptArgs = ''
)
$ErrorActionPreference = 'Stop'
$logs = Join-Path $Root 'logs'
if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Force -Path $logs | Out-Null }

$pidFile = Join-Path $logs "$Name.pid"
if (Test-Path $pidFile) {
    $old = (Get-Content $pidFile -TotalCount 1).Trim()
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
        Write-Output "already running: pid $old (log: $(Get-Content (Join-Path $logs "$Name-latest.txt")))"
        exit 2
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logs "$Name-$stamp.log"
Set-Content -Path (Join-Path $logs "$Name-latest.txt") -Value $log

$wrapper = Join-Path $PSScriptRoot 'keepawake-run.ps1'
$target = Join-Path $PSScriptRoot $Script
$inner = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -PidFile `"$pidFile`" -Target `"$target`" -Root `"$Root`""
if ($ScriptArgs) { $inner += " -ArgString `"$ScriptArgs`"" }
$cmdArgs = "/d /c `"$inner >> `"$log`" 2>&1`""

# 1) WMI: escapes the ssh job object, no artefacts left behind. Needs WMI access (admin over ssh).
$started = $false
try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = "cmd.exe $cmdArgs"
        CurrentDirectory = $PSScriptRoot
    } -ErrorAction Stop
    if ($r.ReturnValue -eq 0) {
        Write-Output "started $Name via WMI (cmd pid $($r.ProcessId))"
        $started = $true
    } else {
        Write-Output "WMI Win32_Process.Create returned $($r.ReturnValue); trying job breakaway"
    }
} catch {
    Write-Output "WMI not available ($($_.Exception.Message.Split([char]10)[0])); trying job breakaway"
}

# 2) CreateProcess with CREATE_BREAKAWAY_FROM_JOB: leaves the ssh session's job object if it allows breakaway.
if (-not $started) {
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OlgaSpawn {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string r, d, t; public int x, y, w, h, cx, cy, fa, fl; public short sw, cr; public IntPtr r2, i, o, e; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hp, ht; public int pid, tid; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static int Start(string cmd, string cwd) {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        // CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x01000000 | 0x08000000 | 0x00000200, IntPtr.Zero, cwd, ref si, out pi))
            return -Marshal.GetLastWin32Error();
        CloseHandle(pi.hp); CloseHandle(pi.ht);
        return pi.pid;
    }
}
'@
        $bpid = [OlgaSpawn]::Start("cmd.exe $cmdArgs", $PSScriptRoot)
        if ($bpid -gt 0) {
            Write-Output "started $Name via job breakaway (cmd pid $bpid)"
            $started = $true
        } else {
            Write-Output "job breakaway refused (win32 error $(-$bpid)); trying a scheduled task"
        }
    } catch {
        Write-Output "job breakaway failed ($($_.Exception.Message)); trying a scheduled task"
    }
}

# 3) One-shot scheduled task for the current user (S4U: runs without a stored password).
#    The task is named OlgaBuild-<Name>; it is removed by the next run-detached call or cleanup.ps1.
if (-not $started) {
    $taskName = "OlgaBuild-$Name"
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs -WorkingDirectory $PSScriptRoot
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 12) -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-Output "started $Name via scheduled task $taskName (S4U, $user)"
        $started = $true
    } catch {
        Write-Output "scheduled task failed: $($_.Exception.Message)"
    }
}

# 4) Last resort: plain detached process. May die with the ssh session on some OpenSSH builds.
if (-not $started) {
    Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
    Write-Output "started $Name via Start-Process (WARNING: may stop if this ssh session ends)"
}
Write-Output "log: $log"
