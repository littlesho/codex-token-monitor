#Requires -Version 5.1
<#
.SYNOPSIS
  Privacy-safe, read-only breakdown of Codex transport records containing response.completed.
.DESCRIPTION
  Returns only aggregates grouped by a fixed set of log sources.
  The SQL engine inspects bodies locally; original payloads, model names, IDs
  and credentials are NEVER printed or returned to PowerShell.
  A text hint is never sufficient to prove which model served a Desktop request.
#>
[CmdletBinding()]
param(
    [string]$CodexHome = '',
    [string]$DbPath = '',
    [string]$ThreadId = '',
    [ValidateRange(100,50000)][int]$MaxRows = 5000,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows only' }
if ($ThreadId -and $ThreadId -notmatch '^[A-Za-z0-9_-]{1,100}$') { throw 'Invalid thread ID format' }
if (-not ("CodexTransportCandidateCounts" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CodexTransportCandidateCounts
{
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db,int milliseconds);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db,byte[] sql,int count,out IntPtr stmt,IntPtr tail);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr stmt,int index,byte[] value,int length,IntPtr destructor);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_int64(IntPtr stmt,int index,long value);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr stmt,int column);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);
    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value + "\0");

    // Read only the newest N rows in each database. The result is a small matrix
    // of integral counts and allowlisted target codes; no SQL text columns leave SQLite.
    private const string Sql = @"
SELECT CASE target
 WHEN 'log' THEN 1
 WHEN 'tungstenite::protocol' THEN 2
 WHEN 'codex_api::endpoint::responses_websocket' THEN 3
 WHEN 'codex_http_client::transport' THEN 4 ELSE 0 END,
 COUNT(*),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%""model""%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%""response""%' AND feedback_log_body LIKE '%""model""%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%""type"":""response.completed""%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%Received message%' OR feedback_log_body LIKE '%SSE event:%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%Sending frame%' OR feedback_log_body LIKE '%Sending message%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN feedback_log_body LIKE '%before response.completed%' OR feedback_log_body LIKE '%missing response.completed%' OR feedback_log_body LIKE '%response.completed not received%' THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id IS NOT NULL THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id=?1 THEN 1 ELSE 0 END),0),
 COALESCE(SUM(CASE WHEN thread_id IS NULL THEN 1 ELSE 0 END),0)
FROM (
 SELECT target,thread_id,feedback_log_body FROM logs ORDER BY id DESC LIMIT ?2
)
WHERE target IN ('log','tungstenite::protocol','codex_api::endpoint::responses_websocket','codex_http_client::transport')
  AND feedback_log_body LIKE '%response.completed%'
GROUP BY target";

    public static long[][] Read(string path,string threadId,int count)
    {
        IntPtr db=IntPtr.Zero,stmt=IntPtr.Zero;
        try
        {
            if(sqlite3_open_v2(Utf8(path),out db,1 /* SQLITE_OPEN_READONLY */,IntPtr.Zero)!=0)
                throw new InvalidOperationException("Unable to open SQLite read-only");
            sqlite3_busy_timeout(db,250);
            if(sqlite3_prepare_v2(db,Utf8(Sql),-1,out stmt,IntPtr.Zero)!=0)
                throw new InvalidOperationException("SQLite log schema unavailable");
            byte[] id=Utf8(threadId);
            if(sqlite3_bind_text(stmt,1,id,id.Length-1,new IntPtr(-1))!=0 || sqlite3_bind_int64(stmt,2,count)!=0)
                throw new InvalidOperationException("SQLite bind error");
            var rows=new List<long[]>();
            int status;
            while((status=sqlite3_step(stmt))==100 /* SQLITE_ROW */)
            {
                var row=new long[11];
                for(int i=0;i<row.Length;i++) row[i]=sqlite3_column_int64(stmt,i);
                rows.Add(row);
            }
            if(status!=101 /* SQLITE_DONE */) throw new InvalidOperationException("SQLite query failed");
            return rows.ToArray();
        }
        finally
        {
            if(stmt!=IntPtr.Zero)sqlite3_finalize(stmt);
            if(db!=IntPtr.Zero)sqlite3_close(db);
        }
    }
}
'@
}
if (-not $CodexHome) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
$paths = [System.Collections.Generic.List[string]]::new()
if ($DbPath) {
    $paths.Add([System.IO.Path]::GetFullPath($DbPath))
} else {
    if ($env:CODEX_SQLITE_HOME) { $paths.Add((Join-Path $env:CODEX_SQLITE_HOME 'logs_2.sqlite')) }
    $paths.Add((Join-Path $CodexHome 'logs_2.sqlite'))
    $paths.Add((Join-Path $CodexHome 'sqlite\logs_2.sqlite'))
    $paths.Add((Join-Path $CodexHome 'log\logs_2.sqlite'))
}
$existing = @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
$output = @()
$index=0
foreach($path in $existing) {
    $index++
    try {
        $rows = @([CodexTransportCandidateCounts]::Read($path,$ThreadId,$MaxRows))
        foreach($r in $rows) {
            $source = switch ([int]$r[0]) {
                1 { 'log (WebSocket bridge)' }
                2 { 'tungstenite::protocol' }
                3 { 'codex_api::endpoint::responses_websocket' }
                4 { 'codex_http_client::transport' }
                default { 'other allowlisted transport' }
            }
            $output += [pscustomobject][ordered]@{
                Database = "Candidate $index"
                Source = $source
                CompletedTextMatches = $r[1]
                WithModelKeyText = $r[2]
                WithResponseAndModelKeys = $r[3]
                ExactJsonTypeHint = $r[4]
                ReceivedDirectionHints = $r[5]
                SendingDirectionHints = $r[6]
                MissingCompletionErrorHints = $r[7]
                WithAnyThreadId = $r[8]
                WithSelectedThreadId = $r[9]
                WithoutThreadId = $r[10]
            }
        }
    } catch {
        $output += [pscustomobject][ordered]@{
            Database = "Candidate $index"
            Readable = $false
            Reason = 'Read-only SQLite query failed or log schema changed'
        }
    }
}
$report = [pscustomobject][ordered]@{
    ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    CandidateDatabases = $existing.Count
    RecentRowLimit = $MaxRows
    ThreadIdSupplied = -not [string]::IsNullOrWhiteSpace($ThreadId)
    Breakdown = @($output)
    Interpretation = 'All fields are lexical/count hints only; no served model is verified. Unattributed rows must not be assigned to a Desktop session.'
}
if ($AsJson) { $report | ConvertTo-Json -Depth 6 }
else {
    Write-Output 'Codex transport candidate breakdown (READ ONLY, aggregate counts)'
    Write-Output "Candidates: $($existing.Count); per-DB row limit: $MaxRows"
    if (-not $ThreadId) { Write-Output 'No -ThreadId supplied; selected-thread counts will be 0.' }
    if ($output.Count) { $output | Format-List | Out-String | Write-Output }
    else { Write-Output 'No candidate entries in the inspected window.' }
    Write-Output $report.Interpretation
}
