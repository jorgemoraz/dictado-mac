using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text.Json;

namespace Dictado;

/// <summary>
/// Actualización automática desde GitHub: busca la última versión publicada para Windows,
/// la descarga y la cambia por la actual cuando no estás dictando.
/// </summary>
internal sealed class AppUpdater
{
    private const string Repo = "jorgemoraz/dictado-mac";
    private const string AssetName = "DictadoWindows.zip";

    public static Version Current
    {
        get
        {
            var text = Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
            return Version.TryParse(text.Split('+')[0], out var v) ? v : new Version(0, 0, 0);
        }
    }

    /// <summary>Solo las copias instaladas con instalar.ps1 (carpeta «app») se actualizan solas.</summary>
    public static string? InstallRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
            return dir.Name.Equals("app", StringComparison.OrdinalIgnoreCase) && Current > new Version(0, 0, 0) ? dir.Parent?.FullName : null;
        }
    }

    public static string VersionLabel => InstallRoot is null ? $"{Current} · copia manual" : Current.ToString();

    public bool Updating { get; private set; }

    public static async Task<(Version Version, string Url)?> LatestAsync()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Dictado-Windows");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        var json = await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases?per_page=20");
        using var doc = JsonDocument.Parse(json);
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith("windows-v") || release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            if (!Version.TryParse(tag["windows-v".Length..], out var version)) continue;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
                if (asset.GetProperty("name").GetString() == AssetName)
                    return (version, asset.GetProperty("browser_download_url").GetString()!);
        }
        return null;
    }

    /// <summary>Descarga, prepara la carpeta nueva y reinicia la app con ella.</summary>
    public async Task<string> CheckAndInstallAsync(Func<bool> busy, bool manual)
    {
        if (Updating) return "Ya se está actualizando.";
        var root = InstallRoot;
        if (root is null) return manual ? "Esta copia no se instaló con instalar.ps1: no puede actualizarse sola." : "";
        var latest = await LatestAsync();
        if (latest is null) return manual ? "No hay versiones publicadas para Windows." : "";
        if (latest.Value.Version <= Current) return manual ? "Tienes la última versión." : "";
        Updating = true;
        try
        {
            var zip = Path.Combine(Path.GetTempPath(), $"DictadoWindows-{latest.Value.Version}.zip");
            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Dictado-Windows");
                await using var input = await http.GetStreamAsync(latest.Value.Url);
                await using var output = File.Create(zip);
                await input.CopyToAsync(output);
            }
            var staging = Path.Combine(root, "app-new");
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            ZipFile.ExtractToDirectory(zip, staging);
            File.Delete(zip);
            if (!File.Exists(Path.Combine(staging, "DictadoWindows.exe"))) throw new IOException("El paquete descargado no contiene la app.");

            // No reiniciar en mitad de un dictado.
            for (int i = 0; i < 120 && busy(); i++) await Task.Delay(1000);

            var script = Path.Combine(Path.GetTempPath(), "dictado-actualizar.ps1");
            File.WriteAllText(script, $$"""
                $ErrorActionPreference = 'SilentlyContinue'
                Wait-Process -Id {{Environment.ProcessId}} -Timeout 60
                $root = '{{root.Replace("'", "''")}}'
                Remove-Item "$root\app-old" -Recurse -Force
                Rename-Item "$root\app" 'app-old'
                Rename-Item "$root\app-new" 'app'
                Start-Process "$root\app\DictadoWindows.exe" -ArgumentList '--actualizada'
                Start-Sleep -Seconds 5
                Remove-Item "$root\app-old" -Recurse -Force
                """);
            Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
            });
            Log.Write($"Actualizando a {latest.Value.Version}");
            Application.Exit();
            return $"Instalando la versión {latest.Value.Version}…";
        }
        catch (Exception ex)
        {
            Updating = false;
            Log.Write("Actualización fallida: " + ex);
            return "No se ha podido actualizar: " + ex.Message;
        }
    }
}
