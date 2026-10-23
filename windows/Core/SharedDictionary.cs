using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dictado.Core;

/// <summary>
/// Diccionario compartido con Dictado Mac: mismo archivo JSON en iCloud Drive
/// («Dictado Mac/diccionario.json»), mismas reglas de fusión.
/// </summary>
public sealed class SharedDictionary
{
    [JsonPropertyName("terminos")] public List<string> Terminos { get; set; } = new();
    [JsonPropertyName("correcciones")] public Dictionary<string, string> Correcciones { get; set; } = new();
    [JsonPropertyName("eliminados")] public List<string> Eliminados { get; set; } = new();
    [JsonPropertyName("actualizado")][JsonConverter(typeof(Iso8601Converter))] public DateTime Actualizado { get; set; } = DateTime.MinValue;

    /// <summary>Mismo contenido sin importar el orden (cada sistema ordena a su manera).</summary>
    public bool SameContent(SharedDictionary other) =>
        Terminos.ToHashSet().SetEquals(other.Terminos)
        && Eliminados.ToHashSet().SetEquals(other.Eliminados)
        && Correcciones.Count == other.Correcciones.Count
        && Correcciones.All(kv => other.Correcciones.TryGetValue(kv.Key, out var v) && v == kv.Value);

    /// <summary>
    /// Une dos copias. Lo borrado no reaparece desde otro equipo (salvo que se vuelva a añadir
    /// después); en sustituciones con el mismo origen gana la copia más reciente.
    /// </summary>
    public static SharedDictionary Merge(SharedDictionary a, SharedDictionary b)
    {
        var (older, newer) = a.Actualizado <= b.Actualizado ? (a, b) : (b, a);
        var restored = newer.Terminos.Concat(newer.Correcciones.Keys).ToHashSet();
        var removed = newer.Eliminados.ToHashSet();
        removed.UnionWith(older.Eliminados.Where(e => !restored.Contains(e)));

        var seen = new HashSet<string>();
        var terms = new List<string>();
        foreach (var term in newer.Terminos.Concat(older.Terminos))
        {
            var clean = term.Trim();
            var key = clean.ToLowerInvariant();
            if (clean.Length == 0 || removed.Contains(clean) || !seen.Add(key)) continue;
            terms.Add(clean);
        }
        var spanish = CultureInfo.GetCultureInfo("es-ES").CompareInfo;
        terms.Sort((x, y) => spanish.Compare(x, y, CompareOptions.IgnoreCase));

        var corrections = new Dictionary<string, string>(older.Correcciones);
        foreach (var kv in newer.Correcciones) corrections[kv.Key] = kv.Value;
        foreach (var key in removed) corrections.Remove(key);

        return new SharedDictionary
        {
            Terminos = terms,
            Correcciones = corrections,
            Eliminados = removed.OrderBy(e => e, StringComparer.Ordinal).ToList(),
            Actualizado = a.Actualizado > b.Actualizado ? a.Actualizado : b.Actualizado,
        };
    }

    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public string ToJson() => JsonSerializer.Serialize(this, Json);
    public static SharedDictionary FromJson(string json) => JsonSerializer.Deserialize<SharedDictionary>(json, Json) ?? new();

    /// <summary>Swift (.iso8601) no admite fracciones de segundo: «2026-10-23T09:30:00Z».</summary>
    private sealed class Iso8601Converter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTimeOffset.Parse(reader.GetString() ?? "0001-01-01T00:00:00Z", CultureInfo.InvariantCulture).UtcDateTime;

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(DateTime.SpecifyKind(value, DateTimeKind.Utc).ToUniversalTime()
                .ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture));
    }
}

/// <summary>Resultado de sincronizar con el archivo compartido.</summary>
public sealed record SyncResult(SharedDictionary Merged, bool LocalChanged, bool FileWritten, string Status);

public static class DictionaryFileSync
{
    /// <summary>Lee el archivo compartido, fusiona con la copia local y reescribe si hace falta.</summary>
    public static SyncResult Sync(string file, SharedDictionary local, DateTime now)
    {
        var remote = new SharedDictionary();
        bool exists = File.Exists(file);
        if (exists)
        {
            try { remote = SharedDictionary.FromJson(File.ReadAllText(file)); }
            catch (Exception) { return new SyncResult(local, false, false, "No se ha podido leer el diccionario compartido; se conserva el de este equipo."); }
        }
        var merged = SharedDictionary.Merge(local, remote);
        bool localChanged = !merged.SameContent(local);
        bool write = !exists || !merged.SameContent(remote);
        if (write)
        {
            if (now > merged.Actualizado) merged.Actualizado = now;
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var temp = file + ".tmp";
            File.WriteAllText(temp, merged.ToJson());
            File.Move(temp, file, overwrite: true);
        }
        return new SyncResult(merged, localChanged, write,
            $"Sincronizado ({merged.Terminos.Count} términos, {merged.Correcciones.Count} sustituciones).");
    }
}
