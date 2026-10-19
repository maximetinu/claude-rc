#
# Remove the claude-rc autostart scheduled task and everything install.ps1
# created. Never touches claude.exe or your Claude Code configuration.
# The Windows counterpart of uninstall.sh.

param(
  [string]$Label = 'com.claude-rc.autostart',
  [switch]$PurgeLogs,
  [switch]$KillServer,
  [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\lib.ps1')

if ($Help) {
  @"
Usage: .\uninstall.ps1 [options]

Options:
  -Label <id>     task to remove   (default: $DefaultLabel)
  -PurgeLogs      also delete this agent's logs in $LogDir
  -KillServer     also stop a ``claude rc`` server you started by hand in this
                  agent's directory
                  (WARNING: this kills any Claude Code sessions running under it)
  -Help           Show this help

Removing the agent stops the server it started, and the Claude Code sessions
under it. A server you started by hand in the same directory is left alone
unless you pass -KillServer. The shared wrapper and skill are removed only with
the last agent.
"@
  exit 0
}

$LogName = Get-LogName $Label
$WorkDir = Get-AgentDir $Label

Step 'Unloading the agent'
if (Get-AgentTask $Label) {
  if (Stop-Agent $Label) { Ok "stopped the server $Label started" }
  Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $Label -Confirm:$false
  Ok "unregistered $TaskPath$Label"
}
$cfgPath = Config-Path $Label
if (Test-Path $cfgPath) { Remove-Item -Force $cfgPath; Ok "removed $cfgPath" }

Step 'Removing files'
$remaining = Get-InstalledLabels
if ($remaining.Count -gt 0) {
  Info "other agents still use the wrapper and skill - kept: $($remaining -join ' ')"
} else {
  foreach ($f in $ScriptDest, $NativeDest) {
    if (Test-Path $f) { Remove-Item -Force $f; Ok "removed $f" }
  }
  $skill = Get-Item -Force $SkillDest -ErrorAction SilentlyContinue
  if ($skill -and $skill.LinkType) {
    # rmdir removes the link only; Remove-Item could recurse into the target.
    cmd.exe /d /c rmdir "$SkillDest" | Out-Null
    Ok "removed skill link $SkillDest"
  } elseif ($skill) {
    Warn "$SkillDest is a real directory, not ours - left alone"
  }
  if ((Test-Path $ConfigDir) -and -not (Get-ChildItem -Force $ConfigDir)) { Remove-Item $ConfigDir }
  try {
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $svc.GetFolder('\').DeleteFolder($TaskPath.Trim('\'), 0)
    Ok "removed task folder $TaskPath"
  } catch { }
}

if ($PurgeLogs) {
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $LogDir "$LogName.log")
  Ok 'purged logs'
} else {
  Info "logs kept at $(Join-Path $LogDir "$LogName.log") (use -PurgeLogs to delete)"
}

Step 'Running server'
if ($WorkDir) {
  $pids = Get-RcServersIn $WorkDir
} else {
  $pids = @()
  Info "no config was installed for $Label, so its directory is unknown"
}
if ($pids.Count -eq 0) {
  Ok "no 'claude rc' server running$(if ($WorkDir) { " in $WorkDir" })"
} elseif ($KillServer) {
  $tree = Get-ProcessTree $pids
  $tree | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
  Ok "stopped: $($pids -join ' ') (and $($tree.Count - $pids.Count) processes under them)"
} else {
  Info "a server not started by this agent is still running (pids: $($pids -join ' '))."
  Info 'Use -KillServer to stop it now.'
}

Say ''
Write-Host 'Uninstalled.' -ForegroundColor Green
