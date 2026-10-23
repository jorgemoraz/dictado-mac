namespace Dictado;

/// <summary>Pega el texto en la ventana donde estabas, sin dejar rastro en el portapapeles.</summary>
internal static class TextInserter
{
    private const ushort VK_CONTROL = 0x11, VK_V = 0x56;

    public static async Task<(bool Inserted, string Message)> InsertAsync(string text, IntPtr target)
    {
        // Espera a que sueltes el atajo: con Win o Alt pulsados, Ctrl+V haría otra cosa.
        for (int i = 0; i < 50 && AnyModifierDown(); i++) await Task.Delay(20);
        if (Native.GetForegroundWindow() != target)
            return (false, "Has cambiado de ventana: el texto queda en Dictado para copiarlo.");

        var backup = Backup();
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        // Convención de Windows: el historial del portapapeles (Win+V) no lo guarda.
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
        try { Clipboard.SetDataObject(data, false, 5, 50); }
        catch (Exception) { return (false, "No se ha podido usar el portapapeles: el texto queda en Dictado."); }

        await Task.Delay(40);
        Native.SendKeys((VK_CONTROL, false), (VK_V, false), (VK_V, true), (VK_CONTROL, true));
        // Algunas apps leen el portapapeles con retraso: esperar antes de restaurar.
        await Task.Delay(450);
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() == text)
            {
                if (backup is not null) Clipboard.SetDataObject(backup, true, 5, 50);
                else Clipboard.Clear();
            }
        }
        catch (Exception) { }
        return (true, "Texto pegado.");
    }

    private static bool AnyModifierDown() =>
        new[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C }.Any(Native.IsDown);

    private static DataObject? Backup()
    {
        try
        {
            var current = Clipboard.GetDataObject();
            if (current is null) return null;
            var copy = new DataObject();
            bool any = false;
            foreach (var format in current.GetFormats(false))
            {
                try
                {
                    var value = current.GetData(format, false);
                    if (value is null) continue;
                    copy.SetData(format, false, value);
                    any = true;
                }
                catch (Exception) { }
            }
            return any ? copy : null;
        }
        catch (Exception) { return null; }
    }
}
