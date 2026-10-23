using Dictado.Core;

namespace Dictado;

/// <summary>Ventana de Dictado: atajos, modelo, diccionario, último dictado y versión.</summary>
internal sealed class MainForm : Form
{
    private readonly TrayApp app;
    private readonly Label status = new() { AutoSize = true, Font = new Font("Segoe UI", 10f) };
    private readonly ListBox triggers = new() { Height = 70, Width = 420 };
    private readonly Button recordButton = new() { Text = "Añadir atajo…", AutoSize = true };
    private readonly Label shortcutMessage = new() { AutoSize = true, ForeColor = Color.DarkOrange, MaximumSize = new Size(600, 0) };
    private readonly ComboBox model = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 330 };
    private readonly CheckBox styleByApp = new() { Text = "Puntuación según la app (formal en el correo, informal en chats)", AutoSize = true };
    private readonly CheckBox autostart = new() { Text = "Abrir Dictado al iniciar Windows", AutoSize = true };
    private readonly TextBox term = new() { Width = 260, PlaceholderText = "Nombre o término" };
    private readonly Label vocabulary = new() { AutoSize = true, MaximumSize = new Size(600, 0), ForeColor = Color.DimGray };
    private readonly TextBox from = new() { Width = 200, PlaceholderText = "Reconoció" };
    private readonly TextBox to = new() { Width = 200, PlaceholderText = "Debe decir" };
    private readonly Label syncStatus = new() { AutoSize = true, MaximumSize = new Size(600, 0), ForeColor = Color.DimGray };
    private readonly TextBox lastText = new() { Multiline = true, Height = 90, Width = 600, ScrollBars = ScrollBars.Vertical };
    private readonly Label versionLabel = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly Label updateStatus = new() { AutoSize = true, ForeColor = Color.DimGray, MaximumSize = new Size(400, 0) };

    public MainForm(TrayApp app)
    {
        this.app = app;
        Text = "Dictado";
        Font = new Font("Segoe UI", 9.5f);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(660, 760);
        MinimumSize = new Size(560, 500);
        Icon = TrayApp.AppIcon;

        var root = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(16) };
        Controls.Add(root);

        root.Controls.Add(new Label { Text = "Dictado", Font = new Font("Segoe UI Semibold", 16f), AutoSize = true });
        root.Controls.Add(status);

        var shortcuts = Section(root, "Atajos: mantén uno pulsado para hablar y suéltalo para terminar");
        shortcuts.Controls.Add(triggers);
        var shortcutButtons = Row(shortcuts);
        recordButton.Click += (_, _) => app.ToggleRecordingShortcut();
        var remove = new Button { Text = "Quitar", AutoSize = true };
        remove.Click += (_, _) => { if (triggers.SelectedIndex >= 0) app.RemoveTrigger(triggers.SelectedIndex); };
        var restore = new Button { Text = "Restaurar Ctrl + Win y Ctrl + Alt", AutoSize = true };
        restore.Click += (_, _) => app.RestoreTriggers();
        shortcutButtons.Controls.AddRange(new Control[] { recordButton, remove, restore });
        shortcuts.Controls.Add(shortcutMessage);
        shortcuts.Controls.Add(Hint("Las combinaciones solo de modificadoras se activan tras 0,15 s para no chocar con otros atajos."));

        var options = Section(root, "Opciones");
        var modelRow = Row(options);
        modelRow.Controls.Add(new Label { Text = "Modelo de voz:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
        foreach (var m in WhisperEngine.Models) model.Items.Add(m.Label);
        model.SelectedIndexChanged += (_, _) => { if (model.Focused) app.ChangeModel(WhisperEngine.Models[model.SelectedIndex].Id); };
        modelRow.Controls.Add(model);
        styleByApp.CheckedChanged += (_, _) => { if (styleByApp.Focused) app.SetStyleByApp(styleByApp.Checked); };
        autostart.CheckedChanged += (_, _) => { if (autostart.Focused) app.SetAutostart(autostart.Checked); };
        options.Controls.Add(styleByApp);
        options.Controls.Add(autostart);
        options.Controls.Add(Hint("Todo se reconoce en este PC con Whisper: el audio no sale del ordenador."));

        var dictionary = Section(root, "Diccionario personal (compartido con tus Macs por iCloud Drive)");
        var termRow = Row(dictionary);
        var add = new Button { Text = "Añadir", AutoSize = true };
        add.Click += (_, _) => { app.AddTerm(term.Text); term.Clear(); };
        var removeTerm = new Button { Text = "Quitar", AutoSize = true };
        removeTerm.Click += (_, _) => { app.RemoveEntry(term.Text); term.Clear(); };
        var import = new Button { Text = "Importar TXT/CSV", AutoSize = true };
        import.Click += (_, _) => app.ImportDictionary(this);
        termRow.Controls.AddRange(new Control[] { term, add, removeTerm, import });
        dictionary.Controls.Add(vocabulary);
        var correctionRow = Row(dictionary);
        var save = new Button { Text = "Guardar sustitución", AutoSize = true };
        save.Click += (_, _) => { app.SaveCorrection(from.Text, to.Text); from.Clear(); to.Clear(); };
        correctionRow.Controls.AddRange(new Control[] { from, to, save });
        dictionary.Controls.Add(syncStatus);

        var last = Section(root, "Último dictado");
        last.Controls.Add(lastText);
        var copy = new Button { Text = "Copiar", AutoSize = true };
        copy.Click += (_, _) => { if (lastText.Text.Length > 0) Clipboard.SetText(lastText.Text); };
        last.Controls.Add(copy);

        var footer = Row(root);
        var check = new Button { Text = "Buscar actualizaciones", AutoSize = true };
        check.Click += async (_, _) => updateStatus.Text = await app.CheckUpdatesAsync(manual: true);
        footer.Controls.AddRange(new Control[] { versionLabel, check, updateStatus });

        Refresh(null);
    }

    private static FlowLayoutPanel Section(Control parent, string title)
    {
        var box = new GroupBox { Text = title, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(10), MinimumSize = new Size(620, 0) };
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Dock = DockStyle.Fill };
        box.Controls.Add(flow);
        parent.Controls.Add(box);
        return flow;
    }

    private static FlowLayoutPanel Row(Control parent)
    {
        var row = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false };
        parent.Controls.Add(row);
        return row;
    }

    private static Label Hint(string text) => new() { Text = text, AutoSize = true, ForeColor = Color.DimGray, MaximumSize = new Size(600, 0) };

    /// <summary>Vuelca el estado del controlador en la ventana.</summary>
    public void Refresh(string? message)
    {
        if (InvokeRequired) { BeginInvoke(() => Refresh(message)); return; }
        status.Text = app.StatusText;
        triggers.Items.Clear();
        foreach (var t in app.Settings.Triggers) triggers.Items.Add(t.Label());
        recordButton.Text = app.RecordingShortcut ? "Pulsa la combinación… (Esc cancela)" : "Añadir atajo…";
        if (message is not null) shortcutMessage.Text = message;
        int index = Array.FindIndex(WhisperEngine.Models, m => m.Id == app.Settings.Modelo);
        if (!model.Focused) model.SelectedIndex = Math.Max(0, index);
        styleByApp.Checked = app.Settings.PuntuacionSegunApp;
        autostart.Checked = Autostart.Enabled;
        var dict = app.Dictionary;
        vocabulary.Text = dict.Terminos.Count == 0 ? "Sin términos todavía." : $"{dict.Terminos.Count} términos: " + string.Join(" · ", dict.Terminos);
        syncStatus.Text = app.SyncStatus + (dict.Correcciones.Count > 0 ? $" Sustituciones: {string.Join(", ", dict.Correcciones.Select(kv => $"{kv.Key} → {kv.Value}"))}." : "");
        if (!lastText.Focused) lastText.Text = app.Settings.UltimoTexto;
        versionLabel.Text = "Versión " + AppUpdater.VersionLabel;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Cerrar la ventana no cierra Dictado: sigue en la bandeja con los atajos activos.
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }
}
