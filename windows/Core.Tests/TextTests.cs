using Dictado.Core;
using Xunit;

public class TextTests
{
    [Theory]
    [InlineData("¿Quedamos mañana a las 10?", "Quedamos mañana a las 10?")]
    [InlineData("Vale, nos vemos luego.", "Vale, nos vemos luego")]
    [InlineData("¡Qué bien! Nos vemos.", "Qué bien! Nos vemos")]
    [InlineData("Bueno...", "Bueno...")]
    public void Informal(string input, string expected) => Assert.Equal(expected, PunctuationStyle.Informal(input));

    [Theory]
    [InlineData("quedamos mañana?", "¿Quedamos mañana?")]
    [InlineData("Hola Ana. te envío el informe", "Hola Ana. Te envío el informe.")]
    [InlineData("Gracias. qué bien!", "Gracias. ¡Qué bien!")]
    [InlineData("¿Puedes revisarlo? Gracias.", "¿Puedes revisarlo? Gracias.")]
    [InlineData("El precio es 2.5 euros", "El precio es 2.5 euros.")]
    public void Formal(string input, string expected) => Assert.Equal(expected, PunctuationStyle.Formal(input));

    [Theory]
    [InlineData("WhatsApp", "", WritingMode.Informal)]
    [InlineData("OUTLOOK", "Bandeja de entrada", WritingMode.Formal)]
    [InlineData("chrome", "Recibidos - Gmail", WritingMode.Formal)]
    [InlineData("msedge", "ChatGPT", WritingMode.Informal)]
    [InlineData("chrome", "Heraldo.es", WritingMode.Neutral)]
    [InlineData("notepad", "", WritingMode.Neutral)]
    public void EstiloSegunApp(string process, string title, WritingMode expected) =>
        Assert.Equal(expected, WritingStyle.Detect(process, title));

    [Fact]
    public void Sustituciones()
    {
        var corrections = new Dictionary<string, string> { ["trovadora"] = "Trobadora", ["la tro"] = "La Tro(b)adora" };
        Assert.Equal("Trabajo en Trobadora; las trovadoras no", ExplicitCorrections.Apply("Trabajo en trovadora; las trovadoras no", corrections));
        Assert.Equal("Uno\n\nDos", ExplicitCorrections.Apply("Uno. Punto y aparte. Dos", new Dictionary<string, string>()));
        Assert.Equal("Cuesta $5", ExplicitCorrections.Apply("Cuesta cinco", new Dictionary<string, string> { ["cinco"] = "$5" }));
    }

    [Fact]
    public void Importador()
    {
        var (rows, invalid) = DictionaryImportParser.Parse("phrase,replacement\nHeraldo\ntrovadora,Trobadora\n\"con, coma\"\na,b,c\n");
        Assert.Equal(1, invalid);
        Assert.Equal(new ImportedRow[] { new ImportedRow.Term("Heraldo"), new ImportedRow.Correction("trovadora", "Trobadora"), new ImportedRow.Term("con, coma") }, rows);
    }
}
