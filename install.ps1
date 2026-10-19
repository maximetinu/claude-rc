#
# Install the claude-rc autostart scheduled task (Windows).
#
# Idempotent: safe to re-run after editing anything in src/ - that is the
# supported way to apply changes. The Windows counterpart of install.sh.
#
# Run it from a PowerShell prompt (arguments after -- are not passed through
# `powershell -File`).

param(
  [string]$Dir = $HOME,
  [string]$Label = 'com.claude-rc.autostart',
  [switch]$NoSkill,
  [Alias('h')][switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$RcArgs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'src\lib.ps1')

if ($Help) {
  @"
Usage: .\install.ps1 [-Dir <path>] [-Label <id>] [-NoSkill] [-- <claude rc arguments>]

Installs a scheduled task that starts ``claude rc`` (Claude Code Remote Control)
headlessly at every logon, so you can open Claude Code sessions from your phone
without remembering to launch anything.

Options:
  -Dir <path>     Directory the server runs in   (required in practice: Claude
                  Code never trusts the home directory)
  -Label <id>     task name                      (default: $DefaultLabel)
  -NoSkill        Do not link the /claude-rc skill into ~\.claude\skills
  -Help           Show this help

Everything after -- is passed to ``claude rc``, e.g. --no-create-session-in-dir.

One server per directory: give each directory its own label under
$LabelPrefix, e.g.

  .\install.ps1 -Dir ~\git\app -Label ${LabelPrefix}app -- --no-create-session-in-dir

After install:
  .\doctor.ps1 [label]        check one agent is healthy
  .\doctor.ps1 -All           check every installed agent
  Get-Content -Wait $LogDir\<log name>.log
"@
  exit 0
}

if (-not $Label.StartsWith($LabelPrefix)) {
  Die "-Label must start with $LabelPrefix so doctor.ps1 and uninstall.ps1 can find it"
}
if ($Label -notmatch '^[A-Za-z0-9._-]+$') { Die "-Label may only contain letters, digits, '.', '_' and '-'" }
$RcArgsLine = (@($RcArgs) | Where-Object { $_ }) -join ' '
if ($RcArgsLine -match '[<>&|^"%]') { Die "unsupported character in claude rc arguments: $RcArgsLine" }

$LogName = Get-LogName $Label
$LogFile = Join-Path $LogDir "$LogName.log"

# ---------------------------------------------------------------- preflight --
Step 'Preflight'

if ($env:OS -ne 'Windows_NT') { Die 'install.ps1 is for Windows; on macOS run ./install.sh' }
Ok "Windows $([Environment]::OSVersion.Version)"

$ClaudeBin = Find-ClaudeBin
if (-not $ClaudeBin) { Die 'could not find claude.exe (looked in ~\.local\bin and on PATH)' }
if ($ClaudeBin -match '[\\/]versions[\\/]') {
  Die "refusing to install: $ClaudeBin is a version-specific path.
       It would break the next time Claude Code auto-updates. Expected the
       stable copy at ~\.local\bin\claude.exe."
}
Ok "claude binary: $ClaudeBin"

if (-not (Test-Path -PathType Container $Dir)) { Die "-Dir $Dir is not a directory" }
$WorkDir = Normalize-Dir (Resolve-Path -LiteralPath $Dir).ProviderPath
Ok "working directory: $WorkDir"

foreach ($other in Get-InstalledLabels) {
  if ($other -eq $Label) { continue }
  if (Same-Dir (Get-AgentDir $other) $WorkDir) {
    Die "$other already serves $WorkDir - use that label, or uninstall it first"
  }
}

switch (Test-WorkspaceTrusted $WorkDir) {
  0 { Ok 'workspace is trusted' }
  2 { Warn 'no ~\.claude.json yet - run `claude` once before relying on this' }
  3 {
    Die "$WorkDir is your home directory, and Claude Code never saves trust for it,
       so ``claude rc`` can never start there. Pick a project directory with -Dir."
  }
  default {
    Die "$WorkDir has not been trusted by Claude Code.
       A scheduled task cannot answer the trust dialog, so the agent would fail
       silently at every logon. Run ``claude`` once in $WorkDir, accept the
       dialog, then re-run this installer. (Trust in a parent folder does not
       reach into a git repository: a repo needs its own.)"
  }
}

# ------------------------------------------------------------------ migrate --
Step 'Removing the previous version of this agent'
if (Get-AgentTask $Label) {
  if (Stop-Agent $Label) { Ok "stopped the running server of $Label" }
  Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $Label -Confirm:$false
  Ok "unregistered $Label"
} else {
  Info 'nothing to remove'
}

# ------------------------------------------------------------------ install --
Step 'Installing files'

foreach ($d in $ScriptsDir, $LogDir, $ConfigDir) { New-Item -ItemType Directory -Force $d | Out-Null }

Copy-Item -Force (Join-Path $SrcDir 'claude-rc-boot.ps1') $ScriptDest
Copy-Item -Force (Join-Path $SrcDir 'native.cs') $NativeDest
Ok "wrapper -> $ScriptDest"

$config = [ordered]@{ bin = $ClaudeBin; dir = $WorkDir; logDir = $LogDir; logName = $LogName; rcArgs = $RcArgsLine }
[IO.File]::WriteAllText((Config-Path $Label), ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Ok "config -> $(Config-Path $Label)"

# conhost --headless gives the wrapper a console with no window, which every
# process under it inherits (sessions get windowless consoles of their own).
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') `
  -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptDest`" -Label $Label"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
# The defaults would kill a persistent server: a 72-hour execution limit, no
# start (and a stop) on battery power, and below-normal priority.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -Priority 4
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskPath $TaskPath -TaskName $Label -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description "Starts claude rc (Claude Code Remote Control) in $WorkDir at logon. Managed by claude-rc ($RepoDir)." | Out-Null
Ok "scheduled task -> $TaskPath$Label"

if (-not $NoSkill) {
  New-Item -ItemType Directory -Force (Split-Path -Parent $SkillDest) | Out-Null
  $existing = Get-Item -Force $SkillDest -ErrorAction SilentlyContinue
  if ($existing -and -not $existing.LinkType) {
    Warn "$SkillDest exists and is not a link - leaving it alone"
  } else {
    # A junction, not a symlink: symlinks need admin or Developer Mode.
    if ($existing) { cmd.exe /d /c rmdir "$SkillDest" | Out-Null }
    New-Item -ItemType Junction -Path $SkillDest -Target (Join-Path $RepoDir 'skills\claude-rc') | Out-Null
    Ok "skill -> $SkillDest"
  }
}

# --------------------------------------------------------------------- load --
Step 'Starting the agent'
$logStart = if (Test-Path $LogFile) { (Get-Item $LogFile).Length } else { 0 }
Start-ScheduledTask -TaskPath $TaskPath -TaskName $Label
Ok "started $Label"

# ------------------------------------------------------------------- verify --
Step 'Verifying'
for ($i = 0; $i -lt 10; $i++) {
  $state = (Get-AgentTask $Label).State
  if ($state -eq 'Running') { break }
  Start-Sleep -Seconds 1
}
if ($state -eq 'Running') {
  Ok 'task state: Running'
} else {
  Bad "task state: $state"
  Info "see $LogFile"
  exit 1
}

# Give the server time to either connect or report why it cannot.
for ($i = 0; $i -lt 20 -and (Get-RcServersIn $WorkDir).Count -eq 0; $i++) { Start-Sleep -Seconds 1 }
Start-Sleep -Seconds 8
$newLog = ''
if (Test-Path $LogFile) {
  $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
  try {
    [void]$fs.Seek($logStart, 'Begin')
    $newLog = (New-Object IO.StreamReader($fs)).ReadToEnd()
  } finally { $fs.Dispose() }
}
$running = (Get-RcServersIn $WorkDir).Count
if ($newLog -match 'already served') {
  Info "Claude Code says $WorkDir is already served: either by a server stopped"
  Info 'moments ago (released within about 3 minutes), or by one you started by'
  Info 'hand in an elevated terminal, which the agent cannot see. The wrapper'
  Info 'retries every minute or two and takes over once the directory is free.'
} elseif ($newLog -match 'FATAL|Error:') {
  Bad 'the server reported an error:'
  ($newLog -split "`n" | Where-Object { $_ -match 'FATAL|Error' }) | ForEach-Object { Info $_ }
  exit 1
} elseif ($newLog -match 'idling') {
  Info "another 'claude rc' already runs in $WorkDir; the agent takes over when it exits"
} elseif ($running -gt 1) {
  Warn "$running 'claude rc' servers are running in $WorkDir"
} elseif ($running -eq 1) {
  Ok "one 'claude rc' server is running in $WorkDir"
} else {
  Info 'no server yet - the wrapper is waiting for the network'
}

Say ''
Write-Host 'Installed.' -ForegroundColor Green -NoNewline
Say ' `claude rc` will now start automatically at every logon.'
Say ''
Info "If you already have one running by hand in $WorkDir, the agent idles"
Info 'until that one exits, then takes over - so nothing is duplicated.'
Say ''
Say "  .\doctor.ps1 $Label   check health"
Say "  Get-Content -Wait $LogFile"
