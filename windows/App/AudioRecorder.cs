using NAudio.Wave;

namespace Dictado;

/// <summary>Graba el micrófono a 16 kHz mono, el formato que espera Whisper.</summary>
internal sealed class AudioRecorder : IDisposable
{
    private readonly object gate = new();
    private readonly List<float> samples = new();
    private WaveInEvent? wave;
    private TaskCompletionSource? stopped;

    public event Action<float>? Level;

    public void Start()
    {
        lock (gate) samples.Clear();
        stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        wave = new WaveInEvent { WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 50 };
        wave.DataAvailable += (_, e) =>
        {
            float energy = 0;
            int count = e.BytesRecorded / 2;
            lock (gate)
            {
                for (int i = 0; i + 1 < e.BytesRecorded; i += 2)
                {
                    float value = BitConverter.ToInt16(e.Buffer, i) / 32768f;
                    samples.Add(value);
                    energy += value * value;
                }
            }
            if (count > 0) Level?.Invoke(MathF.Min(1, MathF.Sqrt(energy / count) * 5));
        };
        wave.RecordingStopped += (_, e) => stopped?.TrySetResult();
        wave.StartRecording();
    }

    /// <summary>Para y devuelve todo lo grabado, incluida la última sílaba en búfer.</summary>
    public async Task<float[]> StopAsync()
    {
        var current = wave;
        if (current is null) return Array.Empty<float>();
        current.StopRecording();
        if (stopped is not null) await Task.WhenAny(stopped.Task, Task.Delay(1000));
        current.Dispose();
        wave = null;
        lock (gate) return samples.ToArray();
    }

    public void Cancel()
    {
        try { wave?.StopRecording(); wave?.Dispose(); } catch (Exception) { }
        wave = null;
    }

    public void Dispose() => Cancel();
}
