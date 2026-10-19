#
# Diagnose the claude-rc autostart setup on Windows. Exits 0 if healthy, 1 if
# something would stop `claude rc` from coming up at the next logon.
# The Windows counterpart of doctor.sh.

param(
  [Parameter(Position = 0)][string]$Label = 'com.claude-rc.autostart',
  [switch]$All,
  [Alias('h')][switch]$Help
)

. (Join-Path $PSScriptRoot 'src\lib.ps1')

if ($Help) {
  @"
Usage: .\doctor.ps1 [label]    check one agent   (default: $DefaultLabel)
       .\doctor.ps1 -All       one line per installed agent; exit 1 if any fails
"@
  exit 0
}

if ($All) {
  $labels = Get-InstalledLabels
  if ($labels.Count -eq 0) { Bad 'no agents installed - run .\install.ps1'; exit 1 }
  $failed = 0
  foreach ($l in $labels) {
    & $PSCommandPath $l *> $null
    if ($LASTEXITCODE -eq 0) {
      Ok "$l  ($(Get-AgentDir $l))"
    } else {
      Bad "$l  ($(Get-AgentDir $l)) - run .\doctor.ps1 $l"
      $failed++
    }
  }
  exit ([int]($failed -gt 0))
}

$LogFile = Join-Path $LogDir "$(Get-LogName $Label).log"
$script:Problems = 0
function Fail([string]$m) { Bad $m; $script:Problems++ }

Step 'Scheduled task'
$task = Get-AgentTask $Label
if ($task) {
  Ok "task present: $TaskPath$Label"
  if ($task.State -eq 'Disabled') {
    Fail "task is DISABLED (Enable-ScheduledTask -TaskPath '$TaskPath' -TaskName '$Label')"
  } else {
    Ok 'task is enabled'
  }
  if ($task.State -eq 'Running') { Ok 'task state: Running' } else { Fail "task state: $($task.State)" }
  $ti = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $Label
  Info "last run: $($ti.LastRunTime)   last result: 0x$('{0:X}' -f $ti.LastTaskResult)   wrapper pids: $((Get-WrapperPids $Label) -join ' ')"
  if (@($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -gt 0) {
    Ok 'starts at logon'
  } else {
    Fail 'task has no logon trigger - re-run .\install.ps1'
  }
  $s = $task.Settings
  if ($s.ExecutionTimeLimit -and $s.ExecutionTimeLimit -ne 'PT0S') {
    Fail "task is killed after $($s.ExecutionTimeLimit) - re-run .\install.ps1"
  }
  if ($s.DisallowStartIfOnBatteries -or $s.StopIfGoingOnBatteries) {
    Fail 'task does not run on battery power - re-run .\install.ps1'
  }
} else {
  Fail "no task $TaskPath$Label - run .\install.ps1"
}

Step 'Files'
$cfg = Get-AgentConfig $Label
if ($cfg) { Ok "config: $(Config-Path $Label)" } else { Fail "missing config: $(Config-Path $Label)" }
foreach ($pair in @(@($ScriptDest, 'claude-rc-boot.ps1'), @($NativeDest, 'native.cs'))) {
  $dest, $src = $pair
  if (Test-Path $dest) {
    Ok "installed: $dest"
    if ((Get-FileHash $dest).Hash -ne (Get-FileHash (Join-Path $SrcDir $src)).Hash) {
      Warn "$dest differs from src\$src - re-run .\install.ps1 to sync"
    }
  } else {
    Fail "missing: $dest"
  }
}
$bin = if ($cfg) { $cfg.bin } else { Find-ClaudeBin }
if ($bin -and (Test-Path -PathType Leaf $bin)) { Ok "claude binary: $bin" } else { Fail "cannot find the claude binary ($bin)" }

Step 'Workspace trust'
$workdir = if ($cfg) { [string]$cfg.dir } else { '' }
if (-not $workdir) {
  Fail 'directory unknown (no config)'
} else {
  switch (Test-WorkspaceTrusted $workdir) {
    0 { Ok "$workdir is trusted by Claude Code" }
    3 { Fail "$workdir is your home directory, which Claude Code never trusts - reinstall with -Dir <project>" }
    default {
      Fail "$workdir is NOT trusted - the agent will fail silently at logon.
       Run ``claude`` there once and accept the trust dialog."
    }
  }
}

Step 'Server'
if ($workdir) {
  $pids = Get-RcServersIn $workdir
  switch ($pids.Count) {
    0 { Warn "no 'claude rc' server running in $workdir right now" }
    1 { Ok "one server running in $workdir (pid $pids)" }
    default { Warn "$($pids.Count) servers running in $workdir (pids: $($pids -join ' '))" }
  }
}

Step 'Network'
$tcp = New-Object System.Net.Sockets.TcpClient
try {
  if ($tcp.ConnectAsync('api.anthropic.com', 443).Wait(3000) -and $tcp.Connected) {
    Ok 'api.anthropic.com:443 reachable'
  } else { Warn 'api.anthropic.com:443 unreachable' }
} catch { Warn 'api.anthropic.com:443 unreachable' } finally { $tcp.Dispose() }

Step 'Recent log'
if (Test-Path $LogFile) {
  Get-Content -Tail 8 -Encoding UTF8 $LogFile | ForEach-Object { Say "  $_" }
} else {
  Info "no log yet at $LogFile"
}

Say ''
if ($script:Problems -eq 0) {
  Write-Host 'Healthy.' -ForegroundColor Green -NoNewline
  Say ' `claude rc` will start on its own at the next logon.'
} else {
  Write-Host "$($script:Problems) problem(s) found." -ForegroundColor Red
}
exit ([int]($script:Problems -gt 0))
