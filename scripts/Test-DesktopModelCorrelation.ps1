#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Isolated synthetic records only; no real Codex data is used.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DesktopCorrelationFixture
{
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db,byte[] sql,IntPtr callback,IntPtr arg,IntPtr error);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    private static byte[] U(string s) => Encoding.UTF8.GetBytes(s+"\0");
    public static void Create(string path,string sql)
    {
        IntPtr db=IntPtr.Zero;
        try {
            if(sqlite3_open_v2(U(path),out db,6 /* SQLITE_OPEN_READWRITE | CREATE */,IntPtr.Zero)!=0)
                throw new Exception("Failed to create synthetic DB");
            if(sqlite3_exec(db,U(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)
                throw new Exception("Failed to insert synthetic DB records");
        } finally { if(db!=IntPtr.Zero) sqlite3_close(db); }
    }
}
'@
$root=Join-Path $env:TEMP ('codex-response-join-fixture-'+[Guid]::NewGuid().ToString('N'))
$fixtureCodexHome=Join-Path $root '.codex'
$sessions=Join-Path $fixtureCodexHome 'sessions'
New-Item -ItemType Directory -Path $sessions -Force | Out-Null
try {
    $thread='11111111-1111-4111-8111-111111111111'
    $rollout=Join-Path $sessions ('rollout-2026-11-09T01-00-00-'+$thread+'.jsonl')
    $lines=@(
       '{"type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111"}}',
       '{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}',
       '{"type":"token_usage_record","payload":{"thread_id":"11111111-1111-4111-8111-111111111111","turn_id":"turn-1","response_id":"resp-verified"}}',
       '{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}',
       '{"type":"token_usage_record","payload":{"thread_id":"22222222-2222-4222-8222-222222222222","turn_id":"turn-2","response_id":"resp-foreign"}}'
    )
    [IO.File]::WriteAllLines($rollout,[string[]]$lines)
    $db=Join-Path $fixtureCodexHome 'logs_2.sqlite'
    $sql=@'
CREATE TABLE logs(id INTEGER PRIMARY KEY,thread_id TEXT,target TEXT,feedback_log_body TEXT);
INSERT INTO logs VALUES(1,NULL,'log','Received message {"type":"response.completed","response":{"id":"resp-verified","model":"gpt-6.1-sol","status":"completed"}}');
INSERT INTO logs VALUES(2,NULL,'log','Sending frame {"type":"response.completed","response":{"id":"resp-verified","model":"gpt-6.2-sol","status":"completed"}}');
INSERT INTO logs VALUES(3,'other-thread','codex_api::endpoint::responses_websocket','{"type":"response.completed","response":{"id":"resp-verified","model":"gpt-6.2-sol","status":"completed"}}');
INSERT INTO logs VALUES(4,NULL,'log','Received message {"type":"response.completed","response":{"id":"resp-foreign","model":"gpt-6.2-sol","status":"completed"}}');
INSERT INTO logs VALUES(5,NULL,'log','Received message {"type":"response.completed","response":{"id":"resp-other","model":"gpt-6.2-sol","status":"completed"}}');
'@
    [DesktopCorrelationFixture]::Create($db,$sql)
    $result= & (Join-Path $PSScriptRoot 'Correlate-DesktopModels.ps1') -ThreadId $thread -CodexHome $fixtureCodexHome -DbPath $db -AsJson | ConvertFrom-Json
    if (-not $result.RolloutFound -or $result.UsageRecords -ne 1 -or $result.DistinctResponseIds -ne 1) {
      throw "Synthetic records failed: usage=$($result.UsageRecords)"
    }
    if ($result.ResponseIdMatches -ne 2 -or $result.ForeignThreadRejections -ne 1) {
      throw "Expected one valid match and one foreign-thread exclusion. matches=$($result.ResponseIdMatches), excluded=$($result.ForeignThreadRejections)"
    }
    if (@($result.Models).Count -ne 1 -or $result.Models[0].ServedModel -ne 'gpt-6.1-sol' -or $result.Models[0].Responses -ne 1 -or $result.CurrentTurnMatchedResponses -ne 0) {
      throw 'Synthetic model evidence was falsely attributed or discarded'
    }
    Write-Output 'PASS strict response-id correlation; request echo, foreign thread and old turn excluded'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
