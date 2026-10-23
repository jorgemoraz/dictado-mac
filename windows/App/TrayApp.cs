using System.Drawing.Drawing2D;
using Dictado.Core;

namespace Dictado;

/// <summary>Controlador: icono en la bandeja, atajos, grabación, Whisper, pegado, diccionario y actualizaciones.</summary>
internal sealed class TrayApp : ApplicationContext
{
    private enum Phase { Preparing, Ready, Recording, Transcribing, Failed }

    private readonly NotifyIcon tray;
    private readonly KeyboardHook hook;
    private readonly AudioRecorder recorder = new();
    private readonly WhisperEngine engine = new();
    private readonly IndicatorForm indicator = new();
    private readonly AppUpdater updater = new();
    private readonly System.Windows.Forms.Timer syncTimer = new() { Interval = 30_000 };
    private readonly System.Windows.Forms.Timer updateTimer = new() { Interval = 600_000 };
    private MainForm? form;
    private Phase phase = Phase.Preparing;
    private string statusDetail = "Preparando el modelo de voz…";
    private IntPtr target;
    private string targetProcess = "", targetTitle = "";
    private CancellationTokenSource? loading;
    private readonly SynchronizationContext ui;

    public AppSettings Settings { get; } = AppSettings.Load();
    public SharedDictionary Dictionary { get; private set; } = AppSettings.LoadDictionary();
    public string SyncStatus { get; private set; } = "";
    public bool RecordingShortcut { get; private set; }
    public bool Busy => phase is Phase.Recording or Phase.Transcribing;

    public static Icon AppIcon { get; } = CreateIcon();

    public string StatusText => phase switch
    {
        Phase.Ready => "Listo · mantén el atajo para hablar",
        Phase.Recording => "Escuchando · suelta el atajo para terminar",
        Phase.Transcribing => "Transcribiendo…",
        Phase.Failed => "Necesita atención: " + statusDetail,
        _ => statusDetail,
    } + (hook.Installed ? "" : " · los atajos no están activos");

    public TrayApp(bool autostart)
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _ = indicator.Handle; // La ventana del indicador existe desde el principio (recibe el nivel del micro).
        hook = new KeyboardHook(Settings.Triggers);
        hook.Down += OnDown;
        hook.Up += () => _ = OnUpAsync();
        hook.Abort += OnAbort;
        hook.Recorded += OnRecorded;
        hook.Start();

        var menu = new ContextMenuStrip();
        menu.Items.Add("Abrir Dictado", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Salir", null, (_, _) => Quit());
        tray = new NotifyIcon { Icon = AppIcon, Text = "Dictado", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => ShowWindow();

        recorder.Level += level => ui.Post(_ => indicator.SetLevel(level), null);
        syncTimer.Tick += (_, _) => SyncDictionary();
        syncTimer.Start();
        updateTimer.Tick += async (_, _) => await CheckUpdatesAsync(manual: false);
        updateTimer.Start();

        SyncDictionary();
        _ = LoadModelAsync();
        var firstCheck = new System.Windows.Forms.Timer { Interval = 20_000 };
        firstCheck.Tick += async (_, _) => { firstCheck.Stop(); firstCheck.Dispose(); await CheckUpdatesAsync(manual: false); };
        firstCheck.Start();
        if (!autostart) ShowWindow();
    }

    // ── Modelo ─────────────────────────────────────────────────────────────

    private async Task LoadModelAsync()
    {
        loading?.Cancel();
        loading = new CancellationTokenSource();
        var token = loading.Token;
        var model = WhisperEngine.Model(Settings.Modelo);
        phase = Phase.Preparing;
        bool download = !WhisperEngine.IsDownloaded(model);
        statusDetail = download ? $"Descargando el modelo de voz ({model.Bytes / 1_000_000} MB)…" : "Cargando el modelo de voz…";
        if (download) tray.ShowBalloonTip(5000, "Dictado", statusDetail + " Solo la primera vez.", ToolTipIcon.Info);
        Changed();
        int lastPercent = -1;
        var progress = new Progress<double>(p =>
        {
            int percent = (int)(p * 100);
            if (percent == lastPercent) return;
            lastPercent = percent;
            statusDetail = $"Descargando el modelo de voz: {percent} %";
            Changed();
        });
        try
        {
            await engine.LoadAsync(model, progress, token);
            phase = Phase.Ready;
            statusDetail = "";
            if (download) tray.ShowBalloonTip(4000, "Dictado", "Listo. Mantén Ctrl + Win y habla.", ToolTipIcon.Info);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            phase = Phase.Failed;
            statusDetail = "no se ha podido preparar el modelo (" + ex.Message + "). Se reintentará en un minuto.";
            Log.Write("Modelo: " + ex);
            _ = Task.Delay(60_000, token).ContinueWith(t => { if (!t.IsCanceled) ui.Post(_ => _ = LoadModelAsync(), null); }, TaskScheduler.Default);
        }
        Changed();
    }

    public void ChangeModel(string id)
    {
        if (Settings.Modelo == id) return;
        Settings.Modelo = id;
        Settings.Save();
        _ = LoadModelAsync();
    }

    // ── Dictado ────────────────────────────────────────────────────────────

    private void OnDown()
    {
        if (phase == Phase.Preparing || phase == Phase.Failed)
        {
            indicator.ShowState(phase == Phase.Preparing ? "Preparando el modelo…" : "El modelo no está listo");
            _ = Task.Delay(1500).ContinueWith(_ => ui.Post(_ => { if (!Busy) indicator.HideIndicator(); }, null), TaskScheduler.Default);
            return;
        }
        if (phase != Phase.Ready) return;
        target = Native.GetForegroundWindow();
        (targetProcess, targetTitle) = Native.DescribeWindow(target);
        try { recorder.Start(); }
        catch (Exception ex)
        {
            Log.Write("Micrófono: " + ex);
            tray.ShowBalloonTip(5000, "Dictado", "No se puede usar el micrófono. Revisa Configuración → Privacidad → Micrófono.", ToolTipIcon.Warning);
            return;
        }
        phase = Phase.Recording;
        indicator.ShowState("Escuchando");
        Changed();
    }

    private async Task OnUpAsync()
    {
        if (phase != Phase.Recording) return;
        phase = Phase.Transcribing;
        indicator.ShowState("Transcribiendo…");
        Changed();
        string text = "";
        string? problem = null;
        try
        {
            var samples = await recorder.StopAsync();
            text = await Task.Run(() => engine.TranscribeAsync(samples, Dictionary.Terminos));
            text = ExplicitCorrections.Apply(text, Dictionary.Correcciones);
            if (Settings.PuntuacionSegunApp && text.Length > 0)
                text = PunctuationStyle.Apply(text, WritingStyle.Detect(targetProcess, targetTitle));
        }
        catch (Exception ex)
        {
            problem = "Error al transcribir: " + ex.Message;
            Log.Write("Transcripción: " + ex);
        }
        indicator.HideIndicator();
        phase = Phase.Ready;
        if (text.Length > 0)
        {
            Settings.UltimoTexto = text;
            Settings.Save();
            var (inserted, message) = await TextInserter.InsertAsync(text, target);
            if (!inserted) tray.ShowBalloonTip(4000, "Dictado", message, ToolTipIcon.Info);
        }
        else
        {
            tray.ShowBalloonTip(3000, "Dictado", problem ?? "No se ha reconocido voz. Comprueba el micrófono.", ToolTipIcon.Info);
        }
        Changed();
    }

    /// <summary>Se pulsó otra tecla nada más empezar: era otro atajo, no un dictado.</summary>
    private void OnAbort()
    {
        if (phase != Phase.Recording) return;
        recorder.Cancel();
        indicator.HideIndicator();
        phase = Phase.Ready;
        Changed();
    }

    // ── Atajos ─────────────────────────────────────────────────────────────

    public void ToggleRecordingShortcut()
    {
        RecordingShortcut = !RecordingShortcut;
        if (RecordingShortcut) hook.StartRecording(); else hook.CancelRecording();
        Changed();
    }

    private void OnRecorded(HotkeyTrigger? trigger)
    {
        RecordingShortcut = false;
        string message;
        if (trigger is null) message = "Grabación cancelada.";
        else if (trigger.Problem is string problem) message = problem;
        else if (Settings.Triggers.Contains(trigger)) message = "Ese atajo ya está en la lista.";
        else
        {
            Settings.Atajos.Add(TriggerSetting.From(trigger));
            Settings.Save();
            hook.SetTriggers(Settings.Triggers);
            message = "Añadido: " + trigger.Label() + ".";
        }
        Changed(message);
    }

    public void RemoveTrigger(int index)
    {
        if (Settings.Atajos.Count <= 1 || index < 0 || index >= Settings.Atajos.Count) return;
        Settings.Atajos.RemoveAt(index);
        Settings.Save();
        hook.SetTriggers(Settings.Triggers);
        Changed();
    }

    public void RestoreTriggers()
    {
        Settings.Atajos = HotkeyTrigger.Defaults.Select(TriggerSetting.From).ToList();
        Settings.Save();
        hook.SetTriggers(Settings.Triggers);
        Changed("Restaurados Ctrl + Win y Ctrl + Alt izquierdos.");
    }

    public void SetStyleByApp(bool value) { Settings.PuntuacionSegunApp = value; Settings.Save(); Changed(); }

    public void SetAutostart(bool value)
    {
        try { Autostart.Enabled = value; } catch (Exception ex) { Log.Write("Inicio automático: " + ex.Message); }
        Changed();
    }

    // ── Diccionario compartido ─────────────────────────────────────────────

    private void DictionaryChangedLocally()
    {
        Dictionary.Actualizado = DateTime.UtcNow;
        AppSettings.SaveDictionary(Dictionary);
        SyncDictionary();
    }

    private void SyncDictionary()
    {
        if (!Directory.Exists(AppSettings.ICloudDrive))
        {
            SyncStatus = "iCloud para Windows no está instalado: el diccionario solo se guarda en este PC.";
            Changed();
            return;
        }
        try
        {
            var result = DictionaryFileSync.Sync(AppSettings.SharedDictionaryPath, Dictionary, DateTime.UtcNow);
            if (result.LocalChanged || result.FileWritten)
            {
                Dictionary = result.Merged;
                AppSettings.SaveDictionary(Dictionary);
            }
            SyncStatus = "Compartido por iCloud Drive con tus Macs. " + result.Status;
        }
        catch (Exception ex)
        {
            SyncStatus = "No se ha podido sincronizar con iCloud Drive: " + ex.Message;
            Log.Write("Sincronización: " + ex);
        }
        Changed();
    }

    public void AddTerm(string term)
    {
        var clean = term.Trim();
        if (clean.Length == 0 || Dictionary.Terminos.Any(t => t.Equals(clean, StringComparison.OrdinalIgnoreCase))) return;
        Dictionary.Terminos.Add(clean);
        Dictionary.Eliminados.Remove(clean);
        DictionaryChangedLocally();
    }

    public void RemoveEntry(string entry)
    {
        var clean = entry.Trim();
        bool had = Dictionary.Terminos.Remove(clean) | Dictionary.Correcciones.Remove(clean);
        if (!had) { Changed($"«{clean}» no está en el diccionario."); return; }
        if (!Dictionary.Eliminados.Contains(clean)) Dictionary.Eliminados.Add(clean);
        DictionaryChangedLocally();
    }

    public void SaveCorrection(string from, string to)
    {
        var source = from.Trim();
        var destination = to.Trim();
        if (source.Length == 0 || destination.Length == 0) return;
        Dictionary.Correcciones[source] = destination;
        Dictionary.Eliminados.Remove(source);
        DictionaryChangedLocally();
    }

    public void ImportDictionary(IWin32Window owner)
    {
        using var dialog = new OpenFileDialog { Filter = "Texto, CSV o TSV|*.txt;*.csv;*.tsv|Todos los archivos|*.*" };
        if (dialog.ShowDialog(owner) != DialogResult.OK) return;
        var (rows, invalid) = DictionaryImportParser.Parse(File.ReadAllText(dialog.FileName));
        foreach (var row in rows)
        {
            switch (row)
            {
                case ImportedRow.Term t when !Dictionary.Terminos.Contains(t.Value):
                    Dictionary.Terminos.Add(t.Value); Dictionary.Eliminados.Remove(t.Value); break;
                case ImportedRow.Correction c:
                    Dictionary.Correcciones[c.Source] = c.Target; Dictionary.Eliminados.Remove(c.Source); break;
            }
        }
        DictionaryChangedLocally();
        Changed($"Importadas {rows.Count} entradas." + (invalid > 0 ? $" Filas no válidas: {invalid}." : ""));
    }

    // ── Ventana, actualizaciones y salida ──────────────────────────────────

    public Task<string> CheckUpdatesAsync(bool manual) => updater.CheckAndInstallAsync(() => Busy, manual);

    private void ShowWindow()
    {
        form ??= new MainForm(this);
        form.Show();
        if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
        form.Activate();
    }

    private void Changed(string? message = null)
    {
        tray.Text = phase == Phase.Ready ? "Dictado · listo" : "Dictado";
        form?.Refresh(message);
    }

    private void Quit()
    {
        hook.Dispose();
        recorder.Dispose();
        tray.Visible = false;
        engine.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { hook.Dispose(); recorder.Dispose(); engine.Dispose(); tray.Dispose(); indicator.Dispose(); }
        base.Dispose(disposing);
    }

    private static Icon CreateIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var brush = new SolidBrush(Color.FromArgb(10, 132, 255));
            int[] heights = { 10, 20, 28, 20, 10 };
            for (int i = 0; i < heights.Length; i++)
                g.FillRectangle(brush, 4 + i * 5, 16 - heights[i] / 2, 3, heights[i]);
        }
        return Icon.FromHandle(bitmap.GetHicon());
    }
}
