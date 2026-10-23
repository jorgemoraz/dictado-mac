using Dictado.Core;
using Xunit;

public class DictionaryTests
{
    static readonly DateTime Older = DateTime.UnixEpoch.AddSeconds(1000);
    static readonly DateTime Newer = DateTime.UnixEpoch.AddSeconds(2000);

    static SharedDictionary D(string[] terms, Dictionary<string, string>? corr = null, string[]? removed = null, DateTime? date = null) =>
        new() { Terminos = terms.ToList(), Correcciones = corr ?? new(), Eliminados = (removed ?? Array.Empty<string>()).ToList(), Actualizado = date ?? DateTime.MinValue };

    [Fact]
    public void UneYGanaLoReciente()
    {
        var mac = D(new[] { "Zaragoza", "Heraldo", "Xalok" }, new() { ["eraldo"] = "Heraldo" }, date: Newer);
        var pc = D(new[] { "heraldo", "Cosas con Botones" }, new() { ["eraldo"] = "HERALDO", ["trovadora"] = "Trobadora" }, date: Older);
        var merged = SharedDictionary.Merge(mac, pc);
        Assert.Equal(new[] { "Cosas con Botones", "Heraldo", "Xalok", "Zaragoza" }, merged.Terminos);
        Assert.Equal("Heraldo", merged.Correcciones["eraldo"]);
        Assert.Equal("Trobadora", merged.Correcciones["trovadora"]);
        Assert.True(SharedDictionary.Merge(pc, mac).SameContent(merged));
    }

    [Fact]
    public void BorradoNoReapareceSalvoQueSeVuelvaAAnadir()
    {
        var mac = D(new[] { "Zaragoza", "Heraldo", "Xalok" }, new() { ["eraldo"] = "Heraldo" }, date: Newer);
        var deleted = D(new[] { "Heraldo" }, removed: new[] { "Xalok", "eraldo" }, date: Newer.AddSeconds(1000));
        var after = SharedDictionary.Merge(deleted, mac);
        Assert.Equal(new[] { "Heraldo", "Zaragoza" }, after.Terminos);
        Assert.Empty(after.Correcciones);
        var readded = D(new[] { "Heraldo", "Xalok" }, date: Newer.AddSeconds(2000));
        var again = SharedDictionary.Merge(after, readded);
        Assert.Equal(new[] { "Heraldo", "Xalok", "Zaragoza" }, again.Terminos);
        Assert.Equal(new[] { "eraldo" }, again.Eliminados);
    }

    [Fact]
    public void OrdenDistintoEsMismoContenido()
    {
        Assert.True(D(new[] { "a", "B" }).SameContent(D(new[] { "B", "a" })));
    }

    [Fact]
    public void LeeElFormatoDeMac()
    {
        var json = "{\n  \"actualizado\" : \"2026-10-23T09:30:00Z\",\n  \"correcciones\" : {\n    \"trovadora\" : \"Trobadora\"\n  },\n  \"eliminados\" : [],\n  \"terminos\" : [\n    \"Aladín\",\n    \"Heraldo\"\n  ]\n}";
        var d = SharedDictionary.FromJson(json);
        Assert.Equal(new[] { "Aladín", "Heraldo" }, d.Terminos);
        Assert.Equal(new DateTime(2026, 10, 23, 9, 30, 0, DateTimeKind.Utc), d.Actualizado);
        Assert.Contains("\"actualizado\": \"2026-10-23T09:30:00Z\"", d.ToJson());
        Assert.Contains("Aladín", d.ToJson());
    }

    [Fact]
    public void SincronizaConArchivo()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dictado-test-" + Guid.NewGuid());
        var file = Path.Combine(dir, "Dictado Mac", "diccionario.json");
        var local = D(new[] { "Heraldo" }, date: Older);
        var first = DictionaryFileSync.Sync(file, local, Newer);
        Assert.True(first.FileWritten);
        Assert.False(first.LocalChanged);
        var other = D(new[] { "Zaragoza" }, date: Older);
        var second = DictionaryFileSync.Sync(file, other, Newer.AddSeconds(5));
        Assert.True(second.LocalChanged);
        Assert.Equal(new[] { "Heraldo", "Zaragoza" }, second.Merged.Terminos);
        var third = DictionaryFileSync.Sync(file, second.Merged, Newer.AddSeconds(10));
        Assert.False(third.FileWritten);
        Directory.Delete(dir, true);
    }
}
