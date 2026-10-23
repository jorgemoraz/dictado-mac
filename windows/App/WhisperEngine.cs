using System.Text;
using Whisper.net;

namespace Dictado;

internal sealed record WhisperModel(string Id, string Label, string File, long Bytes)
{
    public string Url => $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{File}";
}

/// <summary>Reconocimiento con Whisper en local (whisper.cpp): sin servicios de pago ni envío de audio.</summary>
internal sealed class WhisperEngine : IDisposable
{
    public static readonly WhisperModel[] Models =
    {
        new("turbo", "Máxima calidad · large-v3-turbo (574 MB)", "ggml-large-v3-turbo-q5_0.bin", 574_041_195),
        new("small", "Rápido · small (190 MB)", "ggml-small-q5_1.bin", 190_085_487),
    };

    // Frases que Whisper «inventa» con silencio o ruido (vienen de subtítulos de vídeos).
    private static readonly string[] Hallucinations =
    {
        "amara.org", "subtítulos realizados", "subtitulado por", "gracias por ver", "suscríbete", "¡suscríbete",
        "[música]", "(música)", "[musica]", "[aplausos]", "(aplausos)", "gracias por su atención",
    };

    private readonly SemaphoreSlim gate = new(1, 1);
    private WhisperFactory? factory;
    private string? loadedFile;

    public static string ModelsFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Dictado", "modelos");

    public bool Ready => factory is not null;

    public static WhisperModel Model(string id) => Models.FirstOrDefault(m => m.Id == id) ?? Models[0];

    public static bool IsDownloaded(WhisperModel model)
    {
        var path = Path.Combine(ModelsFolder, model.File);
        return File.Exists(path) && new FileInfo(path).Length == model.Bytes;
    }

    /// <summary>Descarga (si falta) y carga el modelo. Informa del progreso de 0 a 1.</summary>
    public async Task LoadAsync(WhisperModel model, IProgress<double> progress, CancellationToken cancel)
    {
        var path = Path.Combine(ModelsFolder, model.File);
        if (!IsDownloaded(model))
        {
            Directory.CreateDirectory(ModelsFolder);
            var partial = path + ".part";
            using var http = new HttpClient { Timeout = TimeSpan.FromHours(2) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Dictado-Windows");
            using var response = await http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, cancel);
            response.EnsureSuccessStatusCode();
            await using (var input = await response.Content.ReadAsStreamAsync(cancel))
            await using (var output = File.Create(partial))
            {
                var buffer = new byte[1 << 20];
                long total = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancel)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancel);
                    total += read;
                    progress.Report((double)total / model.Bytes);
                }
            }
            if (new FileInfo(partial).Length != model.Bytes)
            {
                File.Delete(partial);
                throw new IOException("La descarga del modelo no está completa. Se reintentará.");
            }
            File.Move(partial, path, overwrite: true);
        }
        await gate.WaitAsync(cancel);
        try
        {
            if (loadedFile == path && factory is not null) return;
            var next = await Task.Run(() => WhisperFactory.FromPath(path), cancel);
            factory?.Dispose();
            factory = next;
            loadedFile = path;
        }
        finally { gate.Release(); }
    }

    /// <summary>Transcribe en español. El diccionario se pasa como contexto para acertar nombres.</summary>
    public async Task<string> TranscribeAsync(float[] samples, IReadOnlyList<string> vocabulary)
    {
        if (samples.Length < 16000 * 0.3) return "";
        double energy = 0;
        foreach (var s in samples) energy += s * s;
        if (Math.Sqrt(energy / samples.Length) < 0.003) return "";

        await gate.WaitAsync();
        try
        {
            if (factory is null) throw new InvalidOperationException("El modelo de voz aún no está listo.");
            var prompt = new StringBuilder("Dictado en español de España, con buena puntuación.");
            if (vocabulary.Count > 0)
            {
                prompt.Append(" Vocabulario: ");
                prompt.Append(string.Join(", ", vocabulary.Take(80)));
                prompt.Append('.');
            }
            using var processor = factory.CreateBuilder()
                .WithLanguage("es")
                .WithPrompt(prompt.ToString())
                .WithThreads(Math.Max(2, Environment.ProcessorCount - 2))
                .Build();
            var text = new StringBuilder();
            await foreach (var segment in processor.ProcessAsync(samples))
            {
                var piece = segment.Text.Trim();
                if (piece.Length == 0 || IsHallucination(piece)) continue;
                if (text.Length > 0) text.Append(' ');
                text.Append(piece);
            }
            return text.ToString().Trim();
        }
        finally { gate.Release(); }
    }

    private static bool IsHallucination(string piece)
    {
        var lower = piece.ToLowerInvariant();
        return Hallucinations.Any(h => lower.Contains(h));
    }

    public void Dispose() => factory?.Dispose();
}
