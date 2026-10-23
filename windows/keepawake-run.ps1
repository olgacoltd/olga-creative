# Internal: launched by run-detached.ps1. Holds a keep-awake request for its lifetime and runs -Target.
param(
    [Parameter(Mandatory = $true)] [string]$PidFile,
    [Parameter(Mandatory = $true)] [string]$Target,
    [string]$Root = 'C:\olga-build',
    [string]$ArgString = ''          # extra arguments for -Target, as PowerShell source text
)
Add-Type -Namespace Olga -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
$ES_CONTINUOUS = [uint32]2147483648      # 0x80000000
$ES_SYSTEM_REQUIRED = [uint32]1
[void][Olga.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
# The build must never disturb the person using the machine: Idle priority, inherited by bash/ninja/gcc.
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::Idle } catch { }
Set-Content -Path $PidFile -Value $PID
$start = Get-Date
Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] START $Target $ArgString (pid $PID, keep-awake on)"
$rc = 0
try {
    Invoke-Expression "& '$Target' -Root '$Root' $ArgString"
    if (-not $?) { $rc = 1 }
} catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $rc = 1
} finally {
    [void][Olga.Power]::SetThreadExecutionState($ES_CONTINUOUS)
    Remove-Item -Force $PidFile -ErrorAction SilentlyContinue
}
$mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] END rc=$rc after $mins min"
exit $rc
