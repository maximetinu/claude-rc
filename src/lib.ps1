# Shared configuration and helpers for install.ps1 / uninstall.ps1 / doctor.ps1.
# The Windows counterpart of lib.sh. Keep this file ASCII-only: Windows
# PowerShell 5.1 reads BOM-less files as ANSI.

$DefaultLabel = 'com.claude-rc.autostart'
# Every agent this project installs has a label under this prefix, so one
# agent per directory can coexist (see Get-InstalledLabels).
$LabelPrefix = 'com.claude-rc.'
# Scheduled tasks live in their own Task Scheduler folder.
$TaskPath = '\claude-rc\'
$ScriptsDir = Join-Path $HOME '.claude\scripts'
$ScriptDest = Join-Path $ScriptsDir 'claude-rc-boot.ps1'
$NativeDest = Join-Path $ScriptsDir 'claude-rc-native.cs'
$ConfigDir = Join-Path $HOME '.claude\claude-rc'
$LogDir = Join-Path $HOME '.claude\logs'
$SkillDest = Join-Path $HOME '.claude\skills\claude-rc'

$SrcDir = $PSScriptRoot
$RepoDir = Split-Path -Parent $SrcDir
if (-not ('ClaudeRc.Native' -as [type])) { Add-Type -Path (Join-Path $SrcDir 'native.cs') }

function Say([string]$m) { Write-Host $m }
function Step([string]$m) { Write-Host '==> ' -NoNewline; Write-Host $m }
function Ok([string]$m) { Write-Host '  OK   ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn([string]$m) { Write-Host '  WARN ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Bad([string]$m) { Write-Host '  FAIL ' -ForegroundColor Red -NoNewline; Write-Host $m }
function Info([string]$m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Die([string]$m) { Write-Host 'error: ' -ForegroundColor Red -NoNewline; Write-Host $m; exit 1 }

function Normalize-Dir([string]$p) { [ClaudeRc.Native]::NormalizeDir($p) }
function Same-Dir([string]$a, [string]$b) {
  [string]::Equals((Normalize-Dir $a), (Normalize-Dir $b), [StringComparison]::OrdinalIgnoreCase)
}

function Config-Path([string]$label) { Join-Path $ConfigDir "$label.json" }
function Get-AgentConfig([string]$label) {
  $p = Config-Path $label
  if (Test-Path $p) { try { return Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json } catch { } }
  return $null
}
function Get-AgentDir([string]$label) {
  $c = Get-AgentConfig $label
  if ($c) { return [string]$c.dir } else { return '' }
}

function Get-AgentTask([string]$label) {
  Get-ScheduledTask -TaskPath $TaskPath -TaskName $label -ErrorAction SilentlyContinue
}

# Labels of every agent this project has installed, one per element.
function Get-InstalledLabels {
  @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName.StartsWith($LabelPrefix) } | ForEach-Object { $_.TaskName })
}

# Absolute path to claude.exe, or $null. Prefers the stable ~/.local/bin copy,
# which the native installer updates in place.
function Find-ClaudeBin {
  $p = Join-Path $HOME '.local\bin\claude.exe'
  if (Test-Path -PathType Leaf $p) { return $p }
  $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# Log file stem for a label. The default agent keeps claude-rc.log; every other
# agent gets claude-rc.<suffix>.log.
function Get-LogName([string]$label) {
  if ($label -eq $DefaultLabel) { return 'claude-rc' }
  if ($label.StartsWith($LabelPrefix)) { return "claude-rc.$($label.Substring($LabelPrefix.Length))" }
  return "claude-rc.$label"
}

# Innermost git repository root containing <dir>, or $null.
function Get-GitRoot([string]$dir) {
  $d = Normalize-Dir $dir
  while ($d) {
    if (Test-Path (Join-Path $d '.git')) { return $d }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { return $null }
    $d = $parent
  }
  return $null
}

# Claude Code refuses to start in a directory whose trust dialog was never
# accepted, and a scheduled task cannot answer it - so the agent would fail
# silently at every logon. Check up front instead.
#
#   0 trusted   1 not trusted   2 no ~/.claude.json   3 untrusted home directory
#
# Trust in a parent covers a child, but the walk stops at the git repository
# root: a repo inside a trusted folder needs its own trust. Claude Code no
# longer saves trust for $HOME, so an untrusted home can never become trusted;
# a home trusted earlier still works. See docs/findings.md.
function Test-WorkspaceTrusted([string]$dir) {
  $d = Normalize-Dir $dir
  $isHome = Same-Dir $d $HOME
  $cfgFile = Join-Path $HOME '.claude.json'
  try { $cfg = Get-Content -Raw -Encoding UTF8 $cfgFile | ConvertFrom-Json } catch {
    if ($isHome) { return 3 } else { return 2 }
  }
  $trusted = @()
  if ($cfg.projects) {
    foreach ($prop in $cfg.projects.PSObject.Properties) {
      if ($prop.Value.hasTrustDialogAccepted) { $trusted += Normalize-Dir $prop.Name }
    }
  }
  if ($isHome) {
    foreach ($t in $trusted) { if (Same-Dir $t $d) { return 0 } }
    return 3
  }
  $stop = Get-GitRoot $d
  while ($d) {
    foreach ($t in $trusted) { if (Same-Dir $t $d) { return 0 } }
    if ($stop -and (Same-Dir $d $stop)) { return 1 }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { return 1 }
    $d = $parent
  }
  return 1
}

# PIDs of the Remote Control servers whose working directory is <dir>.
function Get-RcServersIn([string]$dir) { @([ClaudeRc.Native]::RcServers($dir)) }

# PIDs of the wrapper processes running for <label>: powershell.exe running the
# installed wrapper with -Label <label>, matched on argv fields.
function Get-WrapperPids([string]$label) {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
      $argv = [ClaudeRc.Native]::SplitArgs($_.CommandLine)
      $file = [Array]::IndexOf($argv, '-File')
      $lab = [Array]::IndexOf($argv, '-Label')
      $file -ge 0 -and $file + 1 -lt $argv.Length -and $argv[$file + 1] -eq $ScriptDest -and
      $lab -ge 0 -and $lab + 1 -lt $argv.Length -and $argv[$lab + 1] -eq $label
    } | ForEach-Object { [int]$_.ProcessId })
}

# <pids> plus all their descendants.
function Get-ProcessTree([int[]]$pids) {
  $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
  $tree = @($pids); $queue = @($pids)
  while ($queue.Count -gt 0) {
    $children = @($all | Where-Object { $queue -contains $_.ParentProcessId } | ForEach-Object { [int]$_.ProcessId })
    $children = @($children | Where-Object { $tree -notcontains $_ })
    $tree += $children; $queue = $children
  }
  return $tree
}

function Get-AliveProcesses([int[]]$pids) {
  @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
}

# Sends Ctrl+C to <pid>'s console from a throwaway process (attaching to a
# console detaches the caller from its own). Returns the helper's verdict.
function Send-CtrlC([int]$procId) {
  $out = [IO.Path]::GetTempFileName()
  $nativeCs = (Join-Path $SrcDir 'native.cs').Replace("'", "''")
  $cmd = "Add-Type -Path '$nativeCs'; [ClaudeRc.Native]::SendCtrlC($procId) | Set-Content -Encoding ASCII '$out'"
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc
  $r = (Get-Content $out -ErrorAction SilentlyContinue) -join ''
  Remove-Item $out -ErrorAction SilentlyContinue
  return $r
}

# Stops the agent's wrapper, its `claude rc` and every session under it.
#
# Stop-ScheduledTask alone is not enough: it ends only the task's own process
# (conhost) and leaves the wrapper, the server and its sessions running as
# orphans. So: Ctrl+C the wrapper's console first, which stops the whole tree
# cleanly, then stop the task, then kill anything left. Ctrl+C must come first
# because it cannot reach the console once conhost is gone. See findings.
function Stop-Agent([string]$label) {
  $wrappers = Get-WrapperPids $label
  $tree = @()
  if ($wrappers.Count -gt 0) {
    $tree = Get-ProcessTree $wrappers
    foreach ($w in $wrappers) {
      $r = Send-CtrlC $w
      if ($r -ne 'ok') { Info "Ctrl+C to wrapper $w`: $r" }
    }
    for ($i = 0; $i -lt 15 -and (Get-AliveProcesses $tree).Count -gt 0; $i++) { Start-Sleep -Seconds 1 }
  }
  $task = Get-AgentTask $label
  if ($task -and $task.State -eq 'Running') {
    Stop-ScheduledTask -TaskPath $TaskPath -TaskName $label -ErrorAction SilentlyContinue
  }
  $left = Get-AliveProcesses $tree
  if ($left.Count -gt 0) {
    Info "force-stopping leftover processes: $($left -join ' ')"
    $left | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
  }
  return $wrappers.Count -gt 0
}
