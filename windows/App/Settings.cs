using System.Text.Json;
using Dictado.Core;
using Microsoft.Win32;

namespace Dictado;

internal sealed record TriggerSetting(ushort Modificadoras, int? Tecla)
{
    public HotkeyTrigger ToTrigger() => new((Mods)Modificadoras, Tecla);
    public static TriggerSetting From(HotkeyTrigger t) => new((ushort)t.Modifiers, t.Key);
}

/// <summary>Ajustes de este PC. El diccionario va aparte porque se comparte con los Macs.</summary>
internal sealed class AppSettings
{
    public List<TriggerSetting> Atajos { get; set; } = HotkeyTrigger.Defaults.Select(TriggerSetting.From).ToList();
    public string Modelo { get; set; } = "turbo";
    public bool PuntuacionSegunApp { get; set; } = true;
    public string UltimoTexto { get; set; } = "";

    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Dictado");
    private static string FilePath => Path.Combine(Folder, "ajustes.json");
    public static string DictionaryPath => Path.Combine(Folder, "diccionario.json");
    public static string LogPath => Path.Combine(Folder, "registro.log");

    /// <summary>Carpeta de iCloud Drive que crea iCloud para Windows; la comparten los Macs.</summary>
    public static string ICloudDrive => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "iCloudDrive");
    public static string SharedDictionaryPath => Path.Combine(ICloudDrive, "Dictado Mac", "diccionario.json");

    public IReadOnlyList<HotkeyTrigger> Triggers => Atajos.Select(a => a.ToTrigger()).ToList();

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch (Exception ex) { Log.Write("Ajustes ilegibles: " + ex.Message); }
        return new AppSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public static SharedDictionary LoadDictionary()
    {
        try { if (File.Exists(DictionaryPath)) return SharedDictionary.FromJson(File.ReadAllText(DictionaryPath)); }
        catch (Exception ex) { Log.Write("Diccionario local ilegible: " + ex.Message); }
        return new SharedDictionary();
    }

    public static void SaveDictionary(SharedDictionary dictionary)
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(DictionaryPath, dictionary.ToJson());
    }
}

internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Dictado";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(Name, $"\"{Application.ExecutablePath}\" --autostart");
            else key.DeleteValue(Name, false);
        }
    }
}

internal static class Log
{
    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            File.AppendAllText(AppSettings.LogPath, $"[{DateTime.Now:yyyy-MM-dd HH.mm.ss}] {message}{Environment.NewLine}");
        }
        catch (Exception) { }
    }
}
