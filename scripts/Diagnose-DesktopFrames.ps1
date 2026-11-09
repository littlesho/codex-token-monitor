#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only check for model-bearing SSE/WebSocket trace records in Codex Desktop SQLite logs.
.DESCRIPTION
  Reports COUNTS ONLY. Does not print log bodies, model names, response IDs,
  session text, credentials, process command lines or filesystem paths.
  Response-frame candidates alone are NOT proof of a model used by a given turn.
.EXAMPLE
  pwsh -NoProfile -File ./scripts/Diagnose-DesktopFrames.ps1
.EXAMPLE
  pwsh -NoProfile -File ./scripts/Diagnose-DesktopFrames.ps1 -AsJson
.EXAMPLE
  pwsh -NoProfile -File ./scripts/Diagnose-DesktopFrames.ps1 -ThreadId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [string]$CodexHome = '',
    [string]$DbPath = '',
    [string]$ThreadId = '',
    [ValidateRange(100, 50000)][int]$MaxRows = 5000,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This read-only SQLite diagnostic is Windows-only.'
}
if ($ThreadId -and $ThreadId -notmatch '^[a-zA-Z0-9_-]{1,100}$') {
    throw 'Invalid thread id. Only letters, digits, underscores and hyphens are allowed.'
}
if (-not ("CodexModelFrameCounts" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexModelFrameCounts
{
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] name, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int count, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr stmt, int index, byte[] value, int count, IntPtr destructor);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr stmt, int col);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s + "\0");

    // LIMIT bounds inspection to the most recent rows; SQL only returns aggregate
    // counts and never transfers sensitive log text to the caller.
    private const string Sql = @"
SELECT COUNT(*),
 COALESCE(SUM(CASE WHEN thread_id=?1 THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.created%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.completed%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.completed%'
  AND feedback_log_body LIKE '%""model""%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id=?1 AND target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.completed%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id=?1 AND target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.completed%'
  AND feedback_log_body LIKE '%""model""%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN target IN ('log','tungstenite::protocol',
    'codex_api::endpoint::responses_websocket','codex_http_client::transport')
  AND feedback_log_body LIKE '%response.completed%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN target='codex_app_server::outgoing_message'
  AND feedback_log_body LIKE '%rawResponse/completed%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%server reported model %' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id IS NULL AND target='codex_api::sse::responses'
  AND feedback_log_body LIKE '%SSE event:%response.completed%' THEN 1 ELSE 0 END),0)
FROM (
 SELECT thread_id,target,feedback_log_body
 FROM logs ORDER BY id DESC LIMIT ?2
)";

    public static long[] ReadCounts(string path, string threadId, int maxRows)
    {
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        try
        {
            if (sqlite3_open_v2(Utf8(path), out db, 1 /* SQLITE_OPEN_READONLY */, IntPtr.Zero) != 0)
                throw new InvalidOperationException("SQLite read-only open failed");
            sqlite3_busy_timeout(db, 250);
            if (sqlite3_prepare_v2(db, Utf8(Sql), -1, out stmt, IntPtr.Zero) != 0)
                throw new InvalidOperationException("The current SQLite log schema cannot be queried");
            var id = Utf8(threadId);
            if (sqlite3_bind_text(stmt, 1, id, id.Length - 1, new IntPtr(-1)) != 0 ||
                sqlite3_bind_int64(stmt, 2, maxRows) != 0)
                throw new InvalidOperationException("SQLite parameter binding failed");
            if (sqlite3_step(stmt) != 100 /* SQLITE_ROW */)
                throw new InvalidOperationException("SQLite aggregate query failed");
            var result = new long[11];
            for (int i = 0; i < result.Length; i++)
                result[i] = sqlite3_column_int64(stmt, i);
            return result;
        }
        finally
        {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }
}
'@
}

if (-not $CodexHome) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$candidates = [System.Collections.Generic.List[string]]::new()
if ($DbPath) {
    $candidates.Add([System.IO.Path]::GetFullPath($DbPath))
} else {
    if ($env:CODEX_SQLITE_HOME) {
        $candidates.Add((Join-Path $env:CODEX_SQLITE_HOME 'logs_2.sqlite'))
    }
    $candidates.Add((Join-Path $CodexHome 'logs_2.sqlite'))
    $candidates.Add((Join-Path $CodexHome 'sqlite\logs_2.sqlite'))
    $candidates.Add((Join-Path $CodexHome 'log\logs_2.sqlite'))
}
$existing = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

$rows = @()
$position = 0
foreach ($path in $existing) {
    $position++
    try {
        $v = [CodexModelFrameCounts]::ReadCounts($path, $ThreadId, $MaxRows)
        $rows += [pscustomobject][ordered]@{
            Database = "Candidate $position"
            Readable = $true
            RecentRows = $v[0]
            MatchingThreadRows = $v[1]
            SseCreatedCandidates = $v[2]
            SseCompletedCandidates = $v[3]
            SseCompletedWithModelText = $v[4]
            ThreadSseCompleted = $v[5]
            ThreadSseCompletedWithModelText = $v[6]
            TransportCompletedCandidates = $v[7]
            RawResponseCompletionNotices = $v[8]
            ExplicitServerModelReports = $v[9]
            UnattributedSseCompleted = $v[10]
        }
    } catch {
        $rows += [pscustomobject][ordered]@{
            Database = "Candidate $position"
            Readable = $false
            Reason = 'SQLite database cannot be read using the expected schema'
        }
    }
}

# Desktop handshake metadata: print only an allowlisted transport label,
# never the rest of the log line.
$desktopTransport = 'not observed'
if ($env:LOCALAPPDATA) {
    $logDirectory = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        $logs = @(Get-ChildItem -LiteralPath $logDirectory -Filter 'codex-desktop-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)
        foreach ($file in $logs) {
            try {
                $tail = @(Get-Content -LiteralPath $file.FullName -Tail 10000 -ErrorAction Stop)
                for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                    $line = [string]$tail[$i]
                    if ($line -notmatch '\[AppServerConnection\]') { continue }
                    if ($line -match '\btransportKind=(stdio|websocket)\b' -or
                        $line -match '\btransport=(stdio|websocket)\b') {
                        $desktopTransport = $Matches[1]
                        break
                    }
                }
                if ($desktopTransport -ne 'not observed') { break }
            } catch {
                continue
            }
        }
    }
}

$result = [pscustomobject][ordered]@{
    ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    CurrentThreadIdSupplied = -not [string]::IsNullOrEmpty($ThreadId)
    RecentRowLimitPerDatabase = $MaxRows
    ExistingDatabases = $existing.Count
    DesktopTransportFromRecentLogs = $desktopTransport
    Databases = @($rows)
    Interpretation = 'Counts are only candidates, not proof of the model for the selected Desktop turn. Unattributed events must never be assigned to a task.'
}
if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Output 'Codex Desktop frame diagnostic (read-only, counts only)'
    Write-Output "Log DBs: $($existing.Count); recent row limit per DB: $MaxRows"
    Write-Output "Desktop transport from a recent log: $desktopTransport (not necessarily the current connection)"
    if (-not $ThreadId) { Write-Output 'No -ThreadId supplied; thread-specific counts will be zero.' }
    if ($rows.Count) { $rows | Format-List | Out-String | Write-Output }
    else { Write-Output 'No candidate logs_2.sqlite found. Use -DbPath to override.' }
    Write-Output $result.Interpretation
}
