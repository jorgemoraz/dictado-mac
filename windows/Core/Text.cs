using System.Text;
using System.Text.RegularExpressions;

namespace Dictado.Core;

public enum WritingMode { Formal, Neutral, Informal }

/// <summary>Transformaciones deterministas: solo tocan signos y mayúsculas, nunca palabras.</summary>
public static class PunctuationStyle
{
    public static string Apply(string text, WritingMode mode) => mode switch
    {
        WritingMode.Informal => Informal(text),
        WritingMode.Formal => Formal(text),
        _ => text,
    };

    /// <summary>Sin signos de apertura y sin punto final (respeta «?», «!» y los puntos suspensivos).</summary>
    public static string Informal(string text)
    {
        var result = text.Replace("¿", "").Replace("¡", "").Replace("  ", " ").Trim();
        if (result.EndsWith('.') && !result.EndsWith("..")) result = result[..^1];
        return result;
    }

    /// <summary>Puntuación completa: abre ¿ y ¡ donde falten, mayúscula al inicio de frase y cierre con punto.</summary>
    public static string Formal(string text)
    {
        var source = text.Trim();
        if (source.Length == 0) return source;
        const string enders = ".?!…";
        var sentences = new List<string>();
        var current = new StringBuilder();
        for (int i = 0; i < source.Length; i++)
        {
            char c = source[i];
            current.Append(c);
            if (enders.IndexOf(c) < 0) continue;
            while (i + 1 < source.Length && enders.IndexOf(source[i + 1]) >= 0) current.Append(source[++i]);
            // Solo es fin de frase si detrás hay espacio o se acaba el texto («2.5», «heraldo.es» siguen juntos).
            if (i + 1 >= source.Length || char.IsWhiteSpace(source[i + 1]))
            {
                sentences.Add(current.ToString());
                current.Clear();
            }
        }
        if (current.ToString().Trim().Length > 0) sentences.Add(current.ToString());

        var output = new StringBuilder();
        for (int position = 0; position < sentences.Count; position++)
        {
            var raw = sentences[position];
            int lead = 0;
            while (lead < raw.Length && char.IsWhiteSpace(raw[lead])) lead++;
            var leading = raw[..lead];
            var sentence = raw[lead..];
            if (sentence.EndsWith('?') && !sentence.Contains('¿')) sentence = "¿" + sentence;
            if (sentence.EndsWith('!') && !sentence.Contains('¡')) sentence = "¡" + sentence;
            sentence = CapitalizeFirstLetter(sentence);
            if (position == sentences.Count - 1 && sentence.Length > 0 && ".?!…:;".IndexOf(sentence[^1]) < 0)
                sentence += ".";
            output.Append(position == 0 ? "" : (leading.Length == 0 ? " " : leading)).Append(sentence);
        }
        return output.ToString();
    }

    private static string CapitalizeFirstLetter(string sentence)
    {
        int index = -1;
        for (int i = 0; i < sentence.Length; i++) if (char.IsLetter(sentence[i])) { index = i; break; }
        if (index < 0) return sentence;
        // Solo si antes de la letra no hay más que signos de apertura o comillas.
        for (int i = 0; i < index; i++) if ("¿¡\"'«“(".IndexOf(sentence[i]) < 0) return sentence;
        return sentence[..index] + char.ToUpper(sentence[index], new System.Globalization.CultureInfo("es-ES")) + sentence[(index + 1)..];
    }
}

/// <summary>Estilo de puntuación según la app y la pestaña donde escribes (versión Windows).</summary>
public static class WritingStyle
{
    private static readonly string[] Browsers = { "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc", "comet", "zen", "atlas" };
    private static readonly string[] FormalApps = { "outlook", "olk", "hxoutlook", "thunderbird", "winword", "mailspring", "em client", "mailbird" };
    private static readonly string[] InformalApps = { "whatsapp", "telegram", "slack", "discord", "ms-teams", "teams", "signal", "chatgpt", "claude", "perplexity", "messenger", "lm studio", "ollama", "codex" };
    private static readonly string[] FormalTitles = { "Gmail", "Outlook", "Correo", "Proton Mail", "Yahoo Mail", "iCloud Mail", "Redactar", "Compose", "Nuevo mensaje", "New Message" };
    private static readonly string[] InformalTitles = { "ChatGPT", "Claude", "WhatsApp", "Gemini", "Perplexity", "Grok", "Telegram", "Slack", "Discord", "Messenger", "Teams", "Copilot", "DeepSeek" };

    public static WritingMode Detect(string processName, string windowTitle)
    {
        var process = processName.ToLowerInvariant();
        if (Browsers.Contains(process))
        {
            if (InformalTitles.Any(t => windowTitle.Contains(t, StringComparison.OrdinalIgnoreCase))) return WritingMode.Informal;
            if (FormalTitles.Any(t => windowTitle.Contains(t, StringComparison.OrdinalIgnoreCase))) return WritingMode.Formal;
            return WritingMode.Neutral;
        }
        if (InformalApps.Contains(process)) return WritingMode.Informal;
        if (FormalApps.Contains(process)) return WritingMode.Formal;
        return WritingMode.Neutral;
    }
}

public static class ExplicitCorrections
{
    private static readonly string[] ParagraphCommands = { "punto y aparte", "nuevo párrafo", "nuevo parrafo" };

    public static string Apply(string text, IReadOnlyDictionary<string, string> corrections)
    {
        var result = text;
        // Frases largas primero; nunca dentro de otra palabra.
        foreach (var source in corrections.Keys.OrderByDescending(k => k.Length))
        {
            var target = corrections[source];
            var regex = new Regex(@"(?<![\p{L}\p{N}])" + Regex.Escape(source) + @"(?![\p{L}\p{N}])", RegexOptions.IgnoreCase);
            result = regex.Replace(result, _ => target);
        }
        foreach (var command in ParagraphCommands)
            result = Regex.Replace(result, @"(?i)(?:[,.]?\s*)\b" + command + @"\b[,.]?\s*", "\n\n");
        return result.Trim();
    }
}

public abstract record ImportedRow
{
    public sealed record Term(string Value) : ImportedRow;
    public sealed record Correction(string Source, string Target) : ImportedRow;
}

/// <summary>TXT, CSV o TSV: un término por línea o pares origen/destino (mismo formato que en Mac).</summary>
public static class DictionaryImportParser
{
    public static (List<ImportedRow> Rows, int Invalid) Parse(string text, char? separator = null)
    {
        var normalized = text.Replace("\r\n", "\n").Replace("\r", "\n");
        char delimiter = separator ?? (normalized.Contains('\t') ? '\t' : ',');
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < normalized.Length; i++)
        {
            char c = normalized[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < normalized.Length && normalized[i + 1] == '"') { field.Append('"'); i++; }
                    else quoted = false;
                }
                else field.Append(c);
            }
            else if (c == '"' && field.Length == 0) quoted = true;
            else if (c == delimiter) { row.Add(field.ToString()); field.Clear(); }
            else if (c == '\n') { row.Add(field.ToString()); rows.Add(row); row = new(); field.Clear(); }
            else field.Append(c);
        }
        if (quoted) return (new(), Math.Max(1, rows.Count + 1));
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); rows.Add(row); }

        var result = new List<ImportedRow>();
        int invalid = 0;
        for (int index = 0; index < rows.Count; index++)
        {
            var cells = rows[index].Select(c => c.Replace("﻿", "").Trim()).ToList();
            if (cells.All(c => c.Length == 0)) continue;
            if (index == 0 && cells.Count >= 2
                && new[] { "phrase", "word", "term", "spoken form" }.Contains(cells[0].ToLowerInvariant())
                && new[] { "replacement", "correction", "correct form" }.Contains(cells[1].ToLowerInvariant())) continue;
            if (cells.Count == 1 && cells[0].Length > 0) result.Add(new ImportedRow.Term(cells[0]));
            else if (cells.Count == 2 && cells[0].Length > 0)
                result.Add(cells[1].Length == 0 ? new ImportedRow.Term(cells[0]) : new ImportedRow.Correction(cells[0], cells[1]));
            else invalid++;
        }
        return (result, invalid);
    }
}
