#Requires -Version 7.0
<#
.SYNOPSIS
  Strict, read-only model correlation using Codex rollout token_usage_record response IDs.
.DESCRIPTION
  Inspects only one selected rollout file plus bounded response-completion SQLite logs.
  It never prints raw log bodies, response IDs, prompts or credentials. It displays
  server-reported model names ONLY after response.id is matched to the selected
  thread's durable token_usage_record and the log is inbound or response-module scoped.
  A matched model is still a server declaration, not an attestation of model weights.
.EXAMPLE
  pwsh -NoProfile -File ./scripts/Correlate-DesktopModels.ps1 -ThreadId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$ThreadId,
    [string]$CodexHome = '',
    [string]$DbPath = '',
    [ValidateRange(100,50000)][int]$MaxRows = 20000,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows only' }
if (-not $CodexHome) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}
if (-not ('CodexResponseJoinV1' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

public static class CodexResponseJoinV1
{
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int length, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr stmt, int col);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr stmt, int col);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    private const string Sql = @"
SELECT target, thread_id, feedback_log_body, ts, process_uuid
FROM (SELECT id,target,thread_id,feedback_log_body,ts,process_uuid FROM logs ORDER BY id DESC LIMIT ?1)
WHERE target IN ('log','tungstenite::protocol',
                 'codex_api::endpoint::responses_websocket',
                 'codex_http_client::transport')
 AND feedback_log_body LIKE '%response.completed%'
 AND length(feedback_log_body)<=2097152
ORDER BY id DESC";
    private const string LogWindowSql =
        "SELECT COUNT(*),MIN(ts),MAX(ts) FROM (SELECT ts FROM logs ORDER BY id DESC LIMIT ?1)";
    private static string Iso(long utcSeconds)
    {
        return utcSeconds>=946684800 && utcSeconds<=253402300799 ?
            DateTimeOffset.FromUnixTimeSeconds(utcSeconds).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") : "unavailable";
    }
    private sealed class LogWindow
    {
        public string Database { get; set; } = "";
        public long RecentRows { get; set; }
        public string OldestRetainedUtc { get; set; } = "";
        public string NewestRetainedUtc { get; set; } = "";
    }
    private static byte[] U(string str) => Encoding.UTF8.GetBytes(str + "\0");
    private static string GetString(IntPtr stmt, int col)
    {
        var ptr = sqlite3_column_text(stmt,col);
        if (ptr == IntPtr.Zero) return "";
        var bytes = sqlite3_column_bytes(stmt,col);
        return bytes > 0 && bytes <= 2097152 ? Marshal.PtrToStringUTF8(ptr,bytes) ?? "" : "";
    }
    private static string Prop(JsonElement e,string name)
    {
        if(e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name,out var p) &&
           p.ValueKind == JsonValueKind.String) return p.GetString() ?? "";
        return "";
    }
    private static bool IdOk(string s)
    {
        return s.Length >= 5 && s.Length <= 180 &&
            s.All(c => char.IsAsciiLetterOrDigit(c) || c=='_' || c=='-' || c=='.');
    }

    private sealed class Report
    {
        public bool RolloutFound { get; set; }
        public bool RolloutReadable { get; set; }
        public string RolloutReadStatus { get; set; } = "not_attempted";
        public int RolloutFileCandidates { get; set; }
        public int UsageRecords { get; set; }
        public int DistinctResponseIds { get; set; }
        public bool LatestTurnKnown { get; set; }
        public int LogDatabasesFound { get; set; }
        public int ReadableLogDatabases { get; set; }
        public int CompletionTextRows { get; set; }
        public int ParsedCompletedFrames { get; set; }
        public int ParseFailures { get; set; }
        public int ResponseIdMatches { get; set; }
        public int ForeignThreadRejections { get; set; }
        public int CurrentTurnMatchedResponses { get; set; }
        public string FirstUsageUtc { get; set; } = "unavailable";
        public string LastUsageUtc { get; set; } = "unavailable";
        public string FirstCompletedCandidateUtc { get; set; } = "unavailable";
        public string LastCompletedCandidateUtc { get; set; } = "unavailable";
        public int ParsedForeignThreadCompletions { get; set; }
        public int ParsedThreadlessCompletions { get; set; }
        public int DistinctTaggedThreads { get; set; }
        public int DistinctProcessPartitions { get; set; }
        public int CandidatesNearLatestUsage15Min { get; set; }
        public List<LogWindow> RecentLogWindows { get; set; } = new List<LogWindow>();
        public List<ModelEvidence> Models { get; set; } = new List<ModelEvidence>();
        public string Interpretation { get; set; } = "";
    }
    private sealed class ModelEvidence
    {
        public string ServedModel { get; set; } = "";
        public int Responses { get; set; }
        public int CurrentTurnResponses { get; set; }
    }

    // Extract a complete JSON object from a logging prefix, handling braces inside strings.
    // Only an actual parsed response.completed event may produce evidence.
    private static bool TryCompleted(string body,out string id,out string model)
    {
        id=""; model="";
        if (!body.Contains("response.completed",StringComparison.Ordinal)) return false;
        int tries=0;
        for(int i=0;i<body.Length && tries<48;i++)
        {
            if(body[i]!='{')continue;
            tries++;
            int level=0,end=-1; bool inside=false,escape=false;
            for(int j=i;j<body.Length;j++)
            {
                var ch=body[j];
                if(inside)
                {
                    if(escape){ escape=false; continue; }
                    if(ch=='\\'){ escape=true;continue; }
                    if(ch=='"'){ inside=false; }
                    continue;
                }
                if(ch=='"'){ inside=true;continue; }
                if(ch=='{'){ level++;continue; }
                if(ch=='}' && --level==0){ end=j;break; }
            }
            if(end<0)continue;
            var json=body.Substring(i,end-i+1);
            i=end; // Avoid parsing nested text as an unrelated event.
            if(!json.Contains("response.completed",StringComparison.Ordinal))continue;
            try
            {
                using var doc=JsonDocument.Parse(json);
                var e=doc.RootElement;
                if(Prop(e,"type")!="response.completed" ||
                   !e.TryGetProperty("response",out var response) ||
                   response.ValueKind!=JsonValueKind.Object)continue;
                string status=Prop(response,"status");
                if(status!="" && status!="completed")continue;
                var responseId=Prop(response,"id");
                var served=Prop(response,"model");
                if(!IdOk(responseId)||!IdOk(served))continue;
                id=responseId;model=served;return true;
            }
            catch(JsonException) { }
        }
        return false;
    }

    public static string Check(string codexHome,string threadId,string dbOverride,int maxRows)
    {
        var result=new Report();
        var responseTurns=new Dictionary<string,string>(StringComparer.Ordinal);
        string latestTurn="";
        long firstUsageEpoch=long.MaxValue, lastUsageEpoch=0;
        long firstCompletedEpoch=long.MaxValue, lastCompletedEpoch=0;
        var taggedThreads=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var processPartitions=new HashSet<string>(StringComparer.Ordinal);

        var folder=Path.Combine(codexHome,"sessions");
        string[] paths=Directory.Exists(folder)
            ? Directory.EnumerateFiles(folder,"rollout-*"+threadId+".jsonl",SearchOption.AllDirectories).Take(3).ToArray()
            : Array.Empty<string>();
        result.RolloutFileCandidates=paths.Length;
        if(paths.Length!=1)
        {
            result.Interpretation=paths.Length==0 ?
                "Selected thread rollout not found; no response ID correlation possible." :
                "More than one rollout has the selected thread ID; refuse ambiguous attribution.";
            return JsonSerializer.Serialize(result);
        }
        result.RolloutFound=true;
        // Streaming input: never retain user prompts or raw model responses.
        try
        {
            // Codex Desktop may keep the rollout open for append. File.ReadLines()
            // requests FileShare.Read, which can conflict with that writer.
            // This handle permits simultaneous writes/deletes and never takes a write lock.
            using var rolloutStream = new FileStream(
                paths[0], FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.SequentialScan);
            using var rolloutReader = new StreamReader(
                rolloutStream, Encoding.UTF8, true, 65536);
            string line;
            while((line = rolloutReader.ReadLine()) != null)
            {
            if(!line.Contains("token_usage_record",StringComparison.Ordinal) &&
               !line.Contains("task_started",StringComparison.Ordinal) &&
               !line.Contains("turn_context",StringComparison.Ordinal))continue;
            try
            {
                using var doc=JsonDocument.Parse(line);
                var e=doc.RootElement;
                string type=Prop(e,"type");
                if(!e.TryGetProperty("payload",out var payload))continue;
                if(type=="token_usage_record")
                {
                    if(!string.Equals(Prop(payload,"thread_id"),threadId,StringComparison.OrdinalIgnoreCase))continue;
                    var rid=Prop(payload,"response_id");
                    var turn=Prop(payload,"turn_id");
                    if(!IdOk(rid)||turn.Length==0)continue;
                    result.UsageRecords++;
                    responseTurns[rid]=turn;
                    if(DateTimeOffset.TryParse(Prop(e,"timestamp"),out var stamp))
                    {
                        var sec=stamp.ToUnixTimeSeconds();
                        if(sec>0){firstUsageEpoch=Math.Min(firstUsageEpoch,sec);lastUsageEpoch=Math.Max(lastUsageEpoch,sec);}
                    }
                    if(responseTurns.Count>20000)
                    {
                        result.Interpretation="More than 20,000 response IDs; bounded safety limit reached.";
                        return JsonSerializer.Serialize(result);
                    }
                }
                else if(type=="event_msg" && Prop(payload,"type")=="task_started")
                {
                    var turn=Prop(payload,"turn_id");
                    if(turn.Length>0)latestTurn=turn;
                }
                else if(type=="turn_context")
                {
                    var turn=Prop(payload,"turn_id");
                    if(turn.Length>0)latestTurn=turn;
                }
            }
                catch(JsonException) { } // An actively appended final JSONL line may be incomplete.
            }
            result.RolloutReadable = true;
            result.RolloutReadStatus = "shared_read_ok";
        }
        catch(Exception ex) when(ex is IOException || ex is UnauthorizedAccessException)
        {
            // No lock bypass, forced snapshot, process shutdown or privileged access.
            // Discard any partially read IDs instead of deriving model claims.
            responseTurns.Clear();
            result.UsageRecords = 0;
            result.DistinctResponseIds = 0;
            result.LatestTurnKnown = false;
            result.RolloutReadable = false;
            result.RolloutReadStatus = "sharing_or_access_denied";
            result.Interpretation =
                "The selected rollout cannot be read with shared-read access. " +
                "Codex may hold an exclusive handle. No model can be verified safely.";
            return JsonSerializer.Serialize(result);
        }
        result.DistinctResponseIds=responseTurns.Count;
        result.LatestTurnKnown=latestTurn.Length>0;
        result.FirstUsageUtc=Iso(firstUsageEpoch);
        result.LastUsageUtc=Iso(lastUsageEpoch);
        if(responseTurns.Count==0)
        {
            result.Interpretation="This rollout has no usable token_usage_record response IDs. Cannot safely join raw network logs to this task.";
            return JsonSerializer.Serialize(result);
        }

        var candidates=new List<string>();
        if(!string.IsNullOrWhiteSpace(dbOverride))candidates.Add(Path.GetFullPath(dbOverride));
        else
        {
            var configured=Environment.GetEnvironmentVariable("CODEX_SQLITE_HOME");
            if(!string.IsNullOrWhiteSpace(configured))candidates.Add(Path.Combine(configured,"logs_2.sqlite"));
            candidates.Add(Path.Combine(codexHome,"logs_2.sqlite"));
            candidates.Add(Path.Combine(codexHome,"sqlite","logs_2.sqlite"));
            candidates.Add(Path.Combine(codexHome,"log","logs_2.sqlite"));
        }
        var seenIds=new Dictionary<string,string>(StringComparer.Ordinal);
        var byModel=new Dictionary<string,ModelEvidence>(StringComparer.OrdinalIgnoreCase);
        foreach(var path in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if(!File.Exists(path))continue;
            result.LogDatabasesFound++;
            IntPtr db=IntPtr.Zero,stmt=IntPtr.Zero;
            try
            {
                if(sqlite3_open_v2(U(path),out db,1 /* READONLY */,IntPtr.Zero)!=0)continue;
                sqlite3_busy_timeout(db,250);
                if(sqlite3_prepare_v2(db,U(Sql),-1,out stmt,IntPtr.Zero)!=0)continue;
                if(sqlite3_bind_int64(stmt,1,maxRows)!=0)continue;
                result.ReadableLogDatabases++;
                // The log has independent per-thread/per-process retention partitions.
                // Read aggregate timestamp coverage only; no log payload leaves SQLite.
                IntPtr coverage=IntPtr.Zero;
                try
                {
                    if(sqlite3_prepare_v2(db,U(LogWindowSql),-1,out coverage,IntPtr.Zero)==0 &&
                       sqlite3_bind_int64(coverage,1,maxRows)==0 &&
                       sqlite3_step(coverage)==100)
                    {
                        result.RecentLogWindows.Add(new LogWindow
                        {
                            Database="Candidate "+result.LogDatabasesFound,
                            RecentRows=sqlite3_column_int64(coverage,0),
                            OldestRetainedUtc=Iso(sqlite3_column_int64(coverage,1)),
                            NewestRetainedUtc=Iso(sqlite3_column_int64(coverage,2))
                        });
                    }
                }
                finally {if(coverage!=IntPtr.Zero)sqlite3_finalize(coverage);}
                while(sqlite3_step(stmt)==100 /* ROW */)
                {
                    result.CompletionTextRows++;
                    var target=GetString(stmt,0);
                    var logThread=GetString(stmt,1);
                    var body=GetString(stmt,2);
                    var eventEpoch=sqlite3_column_int64(stmt,3);
                    var procUuid=GetString(stmt,4);
                    // The generic log bridge can also record outgoing messages;
                    // never treat those as served-model evidence.
                    if((target=="log"||target=="tungstenite::protocol") &&
                       !body.Contains("Received message",StringComparison.Ordinal))continue;
                    if(!TryCompleted(body,out var id,out var model))
                    {
                        result.ParseFailures++;
                        continue;
                    }
                    result.ParsedCompletedFrames++;
                    if(eventEpoch>0)
                    {
                        firstCompletedEpoch=Math.Min(firstCompletedEpoch,eventEpoch);
                        lastCompletedEpoch=Math.Max(lastCompletedEpoch,eventEpoch);
                        if(lastUsageEpoch>0 && Math.Abs((double)(eventEpoch-lastUsageEpoch))<=900)
                            result.CandidatesNearLatestUsage15Min++;
                    }
                    if(logThread.Length==0)result.ParsedThreadlessCompletions++;
                    else
                    {
                        taggedThreads.Add(logThread);
                        if(!string.Equals(logThread,threadId,StringComparison.OrdinalIgnoreCase))
                            result.ParsedForeignThreadCompletions++;
                    }
                    if(procUuid.Length>0)processPartitions.Add(procUuid);
                    if(!responseTurns.TryGetValue(id,out var turnId))continue;
                    result.ResponseIdMatches++;
                    if(logThread.Length>0 && !string.Equals(logThread,threadId,StringComparison.OrdinalIgnoreCase))
                    {
                        result.ForeignThreadRejections++;
                        continue;
                    }
                    // If multiple logs disagree about one response ID, do not
                    // count the same response as validated under both names.
                    if(seenIds.TryGetValue(id,out var prior) &&
                       !string.Equals(prior,model,StringComparison.OrdinalIgnoreCase))
                    {
                        result.Interpretation="Conflicting reported models for one response ID; manual review needed.";
                        result.Models.Clear();
                        return JsonSerializer.Serialize(result);
                    }
                    if(seenIds.ContainsKey(id))continue;
                    seenIds[id]=model;
                    if(!byModel.TryGetValue(model,out var data))
                    {
                        data=new ModelEvidence{ServedModel=model};
                        byModel.Add(model,data);
                    }
                    data.Responses++;
                    if(latestTurn.Length>0 && turnId==latestTurn)
                    {
                        data.CurrentTurnResponses++;
                        result.CurrentTurnMatchedResponses++;
                    }
                }
            }
            catch(Exception ex) when(ex is DllNotFoundException || ex is EntryPointNotFoundException ||
                 ex is IOException || ex is UnauthorizedAccessException ||
                 ex is ArgumentException || ex is InvalidOperationException)
            {
                // A missing or incompatible DB is not proof of a requested/served match.
            }
            finally
            {
                if(stmt!=IntPtr.Zero)sqlite3_finalize(stmt);
                if(db!=IntPtr.Zero)sqlite3_close(db);
            }
        }
        result.FirstCompletedCandidateUtc=Iso(firstCompletedEpoch);
        result.LastCompletedCandidateUtc=Iso(lastCompletedEpoch);
        result.DistinctTaggedThreads=taggedThreads.Count;
        result.DistinctProcessPartitions=processPartitions.Count;
        result.Models=byModel.Values.OrderBy(x=>x.ServedModel,StringComparer.Ordinal).ToList();
        result.Interpretation=result.Models.Count>0 ?
            "Exact response IDs from this rollout matched parsed completed network events. These are server-declared model names, not an attestation of weights. Current-turn attribution requires CurrentTurnMatchedResponses>0." :
            "No strict response ID and completed-event model match. Do not infer the selected Desktop model from other threads or probes.";
        return JsonSerializer.Serialize(result);
    }
}
'@
}
$json=[CodexResponseJoinV1]::Check($CodexHome,$ThreadId,$DbPath,$MaxRows)
if($AsJson) { Write-Output $json; return }
$r=$json | ConvertFrom-Json
Write-Output 'Codex Desktop response-ID join (read-only, strict, no raw content)'
Write-Output "Rollout candidates: $($r.RolloutFileCandidates); readable: $($r.RolloutReadable) ($($r.RolloutReadStatus)); usage records: $($r.UsageRecords); distinct response IDs: $($r.DistinctResponseIds)"
Write-Output "DBs found: $($r.LogDatabasesFound); readable: $($r.ReadableLogDatabases); response texts: $($r.CompletionTextRows)"
Write-Output "Parsed completions: $($r.ParsedCompletedFrames); exact response-ID matches: $($r.ResponseIdMatches); foreign-thread exclusions: $($r.ForeignThreadRejections)"
Write-Output "Current turn known: $($r.LatestTurnKnown); current-turn matched responses: $($r.CurrentTurnMatchedResponses)"
Write-Output "HRTF usage records: $($r.FirstUsageUtc) to $($r.LastUsageUtc)"
Write-Output "Completed candidates: $($r.FirstCompletedCandidateUtc) to $($r.LastCompletedCandidateUtc)"
Write-Output "Candidate origins: $($r.ParsedForeignThreadCompletions) foreign-thread-tagged; $($r.ParsedThreadlessCompletions) threadless; $($r.DistinctTaggedThreads) distinct tagged threads; $($r.DistinctProcessPartitions) process partitions"
Write-Output "Candidates within +/-15min of latest HRTF usage: $($r.CandidatesNearLatestUsage15Min)"
if(@($r.RecentLogWindows).Count) {
    $r.RecentLogWindows | Format-Table Database,RecentRows,OldestRetainedUtc,NewestRetainedUtc -AutoSize | Out-String | Write-Output
}
if(@($r.Models).Count) {
    $r.Models | Format-Table ServedModel,Responses,CurrentTurnResponses -AutoSize | Out-String | Write-Output
} else {
    Write-Output 'No served model can yet be attributed to the requested Desktop thread.'
}
Write-Output $r.Interpretation
