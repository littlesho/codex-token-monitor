# Codex Token Monitor 1.3.8-ui.5

[中文说明](README.md)

A small, local Windows widget for understanding Codex task usage. It shows
input, cached input, output, estimates, account usage snapshots, and separate
main-task and nested-agent usage. This is an independent community tool.

Previews use synthetic logs:

![Widget](docs/images/main.png) ![Task summary](docs/images/details.png)

It reads local session logs and optional model-name evidence from a read-only
SQLite connection. It does not read authentication files, modify Codex data, or
make network requests. Task names may appear on screen; use synthetic data for
public screenshots.

## UI improvements in this fork

The main widget and task summary can be resized by dragging their window edges.
Font size is independent of window size: choose 100%, 125% (default), 150%,
175%, or 200% via the `...` menu. Shortcuts are Ctrl+Plus, Ctrl+Minus,
and Ctrl+0 to reset. Main/detail sizes and font preferences are remembered.
The task selector expands with the window; long content scrolls. Requested
and server-reported model names are shown in the widget when the local logs
contain usable evidence; a missing server report remains unverified. The task
summary includes a copy-model-evidence button.

Text rendering (ui.2): Ideal font metrics, Segoe UI with Microsoft YaHei UI fallback, and grayscale antialiasing by default to avoid ClearType color fringes. Toggle `平滑字体（灰度抗锯齿）` off in the options menu to use ClearType instead. The detail view no longer scales metric text via a fixed-height Viewbox. The app declares PerMonitorV2 DPI awareness to reduce OS bitmap stretching on mixed-DPI displays. Actual multi-monitor behavior should be verified on Windows.

Text rendering (ui.3): Four switchable presets in the `...` menu:
`Sharp` (ClearType + Display metrics + DIP font sizes rounded to physical
pixels), `Natural` (ClearType + Ideal), `Gray` (grayscale + Ideal),
and `Soft` (grayscale + Ideal + Animated hinting). Soft is an
opt-in tradeoff; Microsoft's documentation warns animated hinting can
reduce static text quality. Segoe UI Variable is preferred on Windows 11,
with Segoe UI and Microsoft YaHei UI fallbacks. The menu also shows the
actual window DPI and the independent font-scale preference. Existing
`GrayscaleText` preferences migrate safely. No algorithm can create
additional physical screen pixels; compare presets at native resolution
and without browser/screenshot rescaling.

Model provenance diagnostics (ui.4): If the main widget shows `Unverified`, open `... → 诊断服务器模型来源（只读）`. This reports only the count of SQLite logs and server-model reports associated with the current thread, not log body text, prompts or credentials. It also looks for `logs_2.sqlite` under the Codex data root, `sqlite/`, `log/`, and `CODEX_SQLITE_HOME` when provided to the monitor. Custom SQLite or log directory paths can be supplied via `--model-log=...`. A missing server-model record cannot be guessed from the requested model; no automatic network interception or Codex configuration changes are performed.

Log rollover resilience (ui.5): Current Codex SQLite logging keeps at most 1,000 rows per thread, further limited by about 10 MiB of content. While the selected turn has no confirmed server-model record, the monitor checks the existing SQLite log read-only every 3 seconds and retains verified evidence for the same exact turn/request in process memory. It never carries evidence across turns, sessions or changed requested models. Diagnostic notes when the per-thread log cap is reached. This does not modify Codex logs or enable missing server headers and cannot restore deleted records. Periodic checks stop after evidence is found or when the monitor exits.

## Run

The framework-dependent package needs Windows 10/11 and .NET 8 Desktop Runtime.
Keep the EXE, DLL, deps.json, and runtimeconfig.json together. Double-click
`CodexTokenMonitor.exe`.

The default data directory is the current user's `.codex` directory. `CODEX_HOME`
is respected. Settings use the current user's LocalApplicationData directory,
independent of where the repository or EXE lives.

```powershell
.\CodexTokenMonitor.exe '--codex-home=D:\CodexData'
.\CodexTokenMonitor.exe '--sessions=D:\CodexData\sessions'
.\CodexTokenMonitor.exe --portable
.\CodexTokenMonitor.exe '--diagnose-paths=paths.json'
```

Other overrides: `--settings=...` and `--model-log=...`. Paths support `~` and
environment-variable expansion. Relative paths are resolved against the EXE's
directory. `--portable` only stores widget settings in `data/settings.json`
beside the EXE; Codex session data stays in its original directory.

Path diagnosis writes paths and existence flags without reading session or
authentication contents. Review it before sharing because paths can contain
your username. See the Chinese README for override precedence and full details.

## Build and check

Install the .NET 8 SDK. From the repository root:

```powershell
.\scripts\Build.ps1
.\scripts\Test.ps1
.\scripts\Publish.ps1
```

Output: `artifacts/publish/framework-dependent/`. The project has no third-party
NuGet package dependencies. A self-contained Windows package can be produced with
`./scripts/Publish.ps1 -SelfContained -Runtime win-x64`; that build downloads the
official .NET runtime packs and includes them in its output.

Tests use synthetic local files. GitHub Actions builds, checks, and publishes a
framework-dependent artifact on Windows. It does not publish a release.

## Limits

Cost estimates are not subscription bills. Account usage is a possibly stale
snapshot, and unavailable evidence remains unavailable. Local session schemas
and SQLite locations are internal implementation details and may change.
Archived sessions are not scanned. WSL/Linux data needs an explicit directory
that is accessible from Windows; the UI itself is Windows-only.

Detailed pricing assumptions, counting rules, diagnostics, and known limitations
are documented in [README.md](README.md).
