using System.IO;
using System.Text.Json;

namespace CodexTokenMonitor;

public sealed class MonitorSettings
{
    public bool Topmost { get; set; }
    public bool ShowRemainingQuota { get; set; }
    // Window geometry is in WPF device-independent pixels (DIPs).
    public double? Width { get; set; }
    public double? Height { get; set; }
    public double? DetailWidth { get; set; }
    public double? DetailHeight { get; set; }
    // 1.0 = 100% of original WPF font sizes. Previous settings remain valid.
    public double FontScale { get; set; } = 1.25;
    // Missing fields in older settings.json retain the smoother grayscale default.
    public bool GrayscaleText { get; set; } = true;
    public double? Left { get; set; }
    public double? Top { get; set; }
    private static string SettingsPath => new MonitorPaths().SettingsPath;
    public static MonitorSettings Load()
    {
        try { return JsonSerializer.Deserialize<MonitorSettings>(File.ReadAllText(SettingsPath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { return new(); }
    }
    public void Save()
    {
        try
        {
            var path = SettingsPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, path, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
    }
}
