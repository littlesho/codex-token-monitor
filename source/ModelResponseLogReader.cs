using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace CodexTokenMonitor;

// Read-only access through the SQLite runtime shipped with Windows. No extra package,
// network requests, log configuration changes, or access to authentication files.
public static class ModelResponseLogReader
{
    private const string Sql = "SELECT ts, ts_nanos, target, feedback_log_body FROM logs WHERE thread_id=?1 "
        + "AND target IN ('codex_core::session','codex_core::codex','codex_core::session::session','codex_core::stream_events_utils') "
        + "AND feedback_log_body LIKE '%server reported model %' AND ts>=?2 ORDER BY ts DESC,ts_nanos DESC,id DESC LIMIT 50";
    private static readonly Regex Report = new(@"(?:^|:\s+)server reported model (?<returned>[a-zA-Z0-9_.-]+) (?:\(matches requested model\)|while requested model was (?<requested>[a-zA-Z0-9_.-]+))(?:\s+thread_id=[a-zA-Z0-9-]+)?\s*$", RegexOptions.CultureInvariant);
    private static readonly Regex Turn = new("(?:turn\\.id|turn_id)=\"?(?<id>[a-zA-Z0-9-]+)", RegexOptions.CultureInvariant);

    public static ModelResponseEvidence? ParseReport(string target, string body, string turnId, string requested, DateTime at)
    {
        if (target is not ("codex_core::session" or "codex_core::codex" or "codex_core::session::session" or "codex_core::stream_events_utils")) return null;
        if (string.IsNullOrEmpty(turnId) || string.IsNullOrEmpty(requested) || body.Contains("ToolCall:", StringComparison.Ordinal)) return null;
        var match = Report.Match(body);
        if (!match.Success || !Turn.Matches(body[..match.Index]).Any(m => m.Groups["id"].Value == turnId)) return null;
        var returned = match.Groups["returned"].Value;
        var from = match.Groups["requested"].Success ? match.Groups["requested"].Value : returned;
        if (!string.Equals(from, requested, StringComparison.OrdinalIgnoreCase)) return null;
        return new(requested, returned, turnId, at, "运行日志 · server reported model");
    }

    public static ModelResponseEvidence? ReadLatest(string root, string sessionId, string turnId, string requested, DateTime notBefore)
    {
        if (turnId.Length == 0 || requested.Length == 0 || sessionId.Length == 0) return null;
        ModelResponseEvidence? latest = null;
        string[] paths;
        try { paths = DatabasePaths(root); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or IOException) { return null; }
        foreach (var path in paths)
        {
            if (!File.Exists(path)) continue;
            IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
            try
            {
                if (sqlite3_open_v2(Utf8(path), out db, 1 /* SQLITE_OPEN_READONLY */, IntPtr.Zero) != 0) continue;
                sqlite3_busy_timeout(db, 100);
                if (sqlite3_prepare_v2(db, Utf8(Sql), -1, out statement, IntPtr.Zero) != 0) continue;
                var id = Utf8(sessionId);
                if (sqlite3_bind_text(statement, 1, id, id.Length - 1, new IntPtr(-1)) != 0) continue;
                if (sqlite3_bind_int64(statement, 2, new DateTimeOffset(DateTime.SpecifyKind(notBefore, DateTimeKind.Utc)).ToUnixTimeSeconds()) != 0) continue;
                while (sqlite3_step(statement) == 100 /* SQLITE_ROW */)
                {
                    var at = DateTimeOffset.FromUnixTimeSeconds(sqlite3_column_int64(statement, 0)).UtcDateTime.AddTicks(sqlite3_column_int64(statement, 1) / 100);
                    if (at < notBefore) continue;
                    var target = Marshal.PtrToStringUTF8(sqlite3_column_text(statement, 2)) ?? "";
                    var body = Marshal.PtrToStringUTF8(sqlite3_column_text(statement, 3)) ?? "";
                    var result = ParseReport(target, body, turnId, requested, at);
                    if (result is null) continue;
                    if (latest is null || result.ObservedAt > latest.ObservedAt) latest = result;
                    break;
                }
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or ArgumentOutOfRangeException or IOException or UnauthorizedAccessException) { }
            finally
            {
                if (statement != IntPtr.Zero) sqlite3_finalize(statement);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
        return latest;
    }
// Local, read-only diagnosis: only aggregate counts are displayed, never log bodies,
    // task prompts, authentication, response payloads, or database absolute paths.
    public static string Diagnose(string root, string sessionId, string turnId, string requested, DateTime notBefore)
    {
        if (sessionId.Length == 0 || turnId.Length == 0 || requested.Length == 0)
            return "当前会话缺少任务、轮次或请求模型标识，无法安全匹配服务器返回模型。";

        string[] candidates;
        try { candidates = DatabasePaths(root); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or IOException)
        {
            return "日志数据库路径无法解析；请检查 --model-log 参数。";
        }
        var existing = candidates.Where(File.Exists).ToArray();
        if (existing.Length == 0)
            return "没有找到可用的 Codex 模型日志数据库。\n\n已检查 CODEX_SQLITE_HOME、Codex 主目录，以及 sqlite/ 和 log/ 下的 logs_2.sqlite。\n"
                + "如果 Codex 自定义了 sqlite_home 或 log_dir，可通过 --model-log=... 指定 logs_2.sqlite。\n"
                + "只有 turn_context.model 不能证明服务器实际运行的模型。";

        const string diagnosticsSql =
            "SELECT COUNT(*), "
            + "COUNT(CASE WHEN feedback_log_body LIKE '%server reported model %' THEN 1 END), "
            + "COUNT(CASE WHEN ts>=?2 AND feedback_log_body LIKE '%server reported model %' THEN 1 END) "
            + "FROM logs WHERE thread_id=?1";
        long threadRows = 0, modelRows = 0, recentModelRows = 0;
        var readable = 0;
        foreach (var path in existing)
        {
            IntPtr db = IntPtr.Zero, stmt = IntPtr.Zero;
            try
            {
                if (sqlite3_open_v2(Utf8(path), out db, 1 /* SQLITE_OPEN_READONLY */, IntPtr.Zero) != 0)
                    continue;
                sqlite3_busy_timeout(db, 250);
                if (sqlite3_prepare_v2(db, Utf8(diagnosticsSql), -1, out stmt, IntPtr.Zero) != 0)
                    continue;
                var id = Utf8(sessionId);
                if (sqlite3_bind_text(stmt, 1, id, id.Length - 1, new IntPtr(-1)) != 0)
                    continue;
                var cutoff = new DateTimeOffset(DateTime.SpecifyKind(notBefore, DateTimeKind.Utc)).ToUnixTimeSeconds();
                if (sqlite3_bind_int64(stmt, 2, cutoff) != 0)
                    continue;
                if (sqlite3_step(stmt) != 100 /* SQLITE_ROW */)
                    continue;
                readable++;
                threadRows += sqlite3_column_int64(stmt, 0);
                modelRows += sqlite3_column_int64(stmt, 1);
                recentModelRows += sqlite3_column_int64(stmt, 2);
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException
                or BadImageFormatException or ArgumentOutOfRangeException or IOException or UnauthorizedAccessException)
            { }
            finally
            {
                if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }

        var summary = $"已发现 {existing.Length} 个候选日志数据库，其中 {readable} 个可读取。\n"
            + $"当前任务日志 {threadRows} 条，含服务端模型报告 {modelRows} 条，当前轮次请求时间之后 {recentModelRows} 条。\n\n";
        if (readable == 0)
            return summary + "日志数据库存在，但无法按预期结构读取（可能被锁定、权限不足或表结构变化）。\n"
                + "可尝试 F5 刷新，并通过 --model-log 显式指定正确的 logs_2.sqlite。";
        if (threadRows == 0)
            return summary + "数据库中没有该任务的关联日志；Codex App 可能将日志写到其他目录或没有持久化。";
        if (modelRows == 0)
            return summary + "日志可读，但此任务没有服务器模型报告。原因可能是 INFO 日志未保留、响应没有模型标识，或日志已轮转。\n"
                + "这不能证明服务器返回模型与请求模型相同。";
        if (recentModelRows == 0)
            return summary + "存在历史服务器模型报告，但在当前轮次的请求时间之后没有新报告。旧记录不能代表本轮。";
        return summary + "发现模型报告，但没有通过当前轮次 ID、请求模型、时间及日志来源的严格匹配。\n"
            + "可能是日志格式变化、轮次范围不一致；为了避免误判，不会显示猜测的模型名。";
    }

    private static string[] DatabasePaths(string root)
    {
        var overridePath = MonitorPaths.EnvironmentPath("CODEX_TOKEN_MONITOR_MODEL_LOG_PATH");
        if (overridePath is not null)
            return new[] { MonitorPaths.ResolvePath(overridePath) };

        var paths = new List<string>();
        var sqliteHome = MonitorPaths.EnvironmentPath("CODEX_SQLITE_HOME");
        if (sqliteHome is not null)
            paths.Add(Path.Combine(MonitorPaths.ResolvePath(sqliteHome), "logs_2.sqlite"));
        paths.Add(Path.Combine(root, "logs_2.sqlite"));
        paths.Add(Path.Combine(root, "sqlite", "logs_2.sqlite"));
        paths.Add(Path.Combine(root, "log", "logs_2.sqlite"));
        return paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + '\0');
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] value, int length, IntPtr destructor);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern long sqlite3_column_int64(IntPtr statement, int index);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr sqlite3_column_text(IntPtr statement, int index);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_finalize(IntPtr statement);
}
