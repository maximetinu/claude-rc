#
# claude-rc - launch `claude rc` (Claude Code Remote Control) headlessly at
# logon on Windows. The Windows counterpart of claude-rc-boot.sh.
#
# This script is what the scheduled task installed by install.ps1 runs, inside
# a windowless console (conhost --headless). It is deliberately generic: the
# task passes only -Label, and everything else comes from that agent's config
# file, so this file never needs templating:
#
#   ~/.claude/claude-rc/<label>.json
#     bin      absolute path to claude.exe
#     dir      directory the Remote Control server runs in
#     logDir   where to write the log
#     logName  log file stem, so each agent has its own
#     rcArgs   extra arguments for `claude rc`, split on spaces
#
# Scheduled tasks have no KeepAlive, so this script is also the supervisor: it
# restarts `claude rc` whenever it exits, at most once a minute.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as
# ANSI. Do not edit the installed copy in ~/.claude/scripts/ - edit this file
# in the repo and re-run install.ps1, which is idempotent.

param([Parameter(Mandatory = $true)][string]$Label)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$ConfigFile = Join-Path $HOME ".claude\claude-rc\$Label.json"
$cfg = Get-Content -Raw -Encoding UTF8 $ConfigFile | ConvertFrom-Json

$ClaudeBin = $cfg.bin
$WorkDir = $cfg.dir
$LogDir = if ($cfg.logDir) { $cfg.logDir } else { Join-Path $HOME '.claude\logs' }
$Log = Join-Path $LogDir "$(if ($cfg.logName) { $cfg.logName } else { 'claude-rc' }).log"
$RcArgs = if ($cfg.rcArgs) { [string]$cfg.rcArgs } else { '' }

New-Item -ItemType Directory -Force $LogDir | Out-Null
function Log([string]$msg) {
  [IO.File]::AppendAllText($Log, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`n", $Utf8)
}

# Trim the log so it can never grow without bound across many logons.
function Trim-Log {
  if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 262144) {
    $tail = Get-Content -Tail 200 -Encoding UTF8 $Log
    [IO.File]::WriteAllLines($Log, [string[]]$tail, $Utf8)
  }
}

# Sessions spawned by the server look `claude` up by name, as in a terminal.
$env:PATH = "$(Join-Path $HOME '.local\bin');$env:PATH"

try {
  Trim-Log
  Log "--- task start (pid $PID, label $Label) ---"
  Log "config: bin=$ClaudeBin dir=$WorkDir"

  if (-not (Test-Path -PathType Leaf $ClaudeBin)) { Log "FATAL: $ClaudeBin does not exist"; exit 1 }
  if (-not (Test-Path -PathType Container $WorkDir)) { Log "FATAL: $WorkDir is not a directory"; exit 1 }

  # The process-matching code is shared with lib.ps1; see native.cs.
  Add-Type -Path (Join-Path $PSScriptRoot 'claude-rc-native.cs')

  while ($true) {
    # 1. At logon the network is usually not up yet; give it up to two
    #    minutes. If it never comes up, run anyway and let the loop retry.
    for ($i = 1; $i -le 24; $i++) {
      $tcp = New-Object System.Net.Sockets.TcpClient
      try {
        if ($tcp.ConnectAsync('api.anthropic.com', 443).Wait(2000) -and $tcp.Connected) { break }
      } catch { } finally { $tcp.Dispose() }
      if ($i -eq 1) { Log "waiting for network..." }
      Start-Sleep -Seconds 5
    }

    # 2. Never double up. If a `claude rc` is already running in this
    #    directory (e.g. one started by hand in a terminal), idle until it
    #    exits and then take over. Claude Code would refuse a second server
    #    here anyway ("already served"); idling keeps that out of the log.
    $waited = $false
    while ([ClaudeRc.Native]::RcServers($WorkDir).Length -gt 0) {
      if (-not $waited) { Log "another 'claude rc' is already running in $WorkDir - idling until it exits" }
      $waited = $true
      Start-Sleep -Seconds 30
    }
    if ($waited) { Log "previous 'claude rc' exited - taking over" }

    Trim-Log
    Set-Location -LiteralPath $WorkDir
    Log "exec: $ClaudeBin rc $RcArgs   (cwd: $WorkDir)"
    $started = Get-Date

    # The status TUI on stdout redraws every few seconds and would grow the log
    # without bound, so it is discarded. Real failures go to stderr and are
    # kept. cmd.exe does the redirection: it appends raw bytes, and Windows
    # PowerShell would re-encode or wrap native stderr.
    & cmd.exe /d /c "`"$ClaudeBin`" rc $RcArgs <NUL >NUL 2>>`"$Log`""
    $code = $LASTEXITCODE
    $ran = [int]((Get-Date) - $started).TotalSeconds
    Log "claude rc exited with code $code after ${ran}s"

    # Like launchd's ThrottleInterval: never restart more than once a minute,
    # so a broken binary cannot hot-loop.
    if ($ran -lt 60) { Start-Sleep -Seconds (60 - $ran) }
  }
} catch {
  Log "FATAL: $($_.Exception.Message)"
  exit 1
}
