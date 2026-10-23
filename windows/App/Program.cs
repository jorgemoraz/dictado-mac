namespace Dictado;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // Una sola copia en marcha; la segunda se cierra sin hacer nada.
        using var mutex = new Mutex(true, @"Local\DictadoWindows", out bool first);
        if (!first) return;
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) => Log.Write("Error: " + e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write("Error grave: " + e.ExceptionObject);
        bool background = args.Contains("--autostart") || args.Contains("--actualizada");
        Application.Run(new TrayApp(background));
    }
}
