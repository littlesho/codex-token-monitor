#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TransportFixture
{
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db,byte[] sql,IntPtr callback,IntPtr arg,IntPtr err);
    [DllImport("winsqlite3",CallingConvention=CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    private static byte[] U(string text) => Encoding.UTF8.GetBytes(text + "\0");
    public static void Create(string path,string sql)
    {
        IntPtr db=IntPtr.Zero;
        try {
            if(sqlite3_open_v2(U(path),out db,6 /* READWRITE + CREATE */,IntPtr.Zero)!=0)
                throw new Exception("Fixture create failed");
            if(sqlite3_exec(db,U(sql),IntPtr.Zero,IntPtr.Zero,IntPtr.Zero)!=0)
                throw new Exception("Fixture SQL failed");
        } finally { if(db!=IntPtr.Zero)sqlite3_close(db); }
    }
}
'@
$root=Join-Path $env:TEMP ('codex-transport-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $file=Join-Path $root 'logs_2.sqlite'
    $sql=@'
CREATE TABLE logs(id INTEGER PRIMARY KEY,thread_id TEXT,target TEXT,feedback_log_body TEXT);
INSERT INTO logs VALUES(1,'sample-thread','log','Received message {"type":"response.completed","response":{"model":"synthetic"}}');
INSERT INTO logs VALUES(2,NULL,'log','Sending frame {"type":"response.completed","response":{"model":"requested"}}');
INSERT INTO logs VALUES(3,'sample-thread','codex_http_client::transport','websocket closed before response.completed');
INSERT INTO logs VALUES(4,'sample-thread','codex_api::sse::responses','SSE event: {"type":"response.completed","response":{"model":"synthetic"}}');
'@
    [TransportFixture]::Create($file,$sql)
    $report = & (Join-Path $PSScriptRoot 'Diagnose-TransportCandidates.ps1') -DbPath $file -ThreadId sample-thread -AsJson | ConvertFrom-Json
    if ($report.CandidateDatabases -ne 1) { throw 'Unexpected candidate count' }
    $bridge=@($report.Breakdown | Where-Object { $_.Source -eq 'log (WebSocket bridge)' })
    if ($bridge.Count -ne 1) { throw 'Missing bridge group' }
    if ($bridge[0].CompletedTextMatches -ne 2 -or $bridge[0].WithModelKeyText -ne 2 -or $bridge[0].ReceivedDirectionHints -ne 1 -or $bridge[0].SendingDirectionHints -ne 1 -or $bridge[0].WithSelectedThreadId -ne 1) {
        throw 'Bridge model/direction counts incorrect'
    }
    $errorGroup=@($report.Breakdown | Where-Object { $_.Source -eq 'codex_http_client::transport' })
    if ($errorGroup.Count -ne 1 -or $errorGroup[0].MissingCompletionErrorHints -ne 1 -or $errorGroup[0].WithModelKeyText -ne 0) {
        throw 'Error-only record classified incorrectly'
    }
    Write-Output 'PASS synthetic transport classifier (no personal data)'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
