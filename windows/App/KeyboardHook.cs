using System.Diagnostics;
using System.Runtime.InteropServices;
using Dictado.Core;

namespace Dictado;

/// <summary>
/// Atajos globales de «mantener para dictar» con un gancho de teclado de bajo nivel.
/// Las modificadoras solo se observan; únicamente se consume la tecla normal de un
/// atajo (para que no se escriba) y lo que se pulsa mientras se graba un atajo nuevo.
/// </summary>
internal sealed class KeyboardHook : IDisposable
{
    private const int DummyVk = 0xE8; // Sin asignar: evita que soltar Win abra el menú Inicio.
    private readonly Native.LowLevelKeyboardProc proc;
    private readonly HotkeyMatcher matcher;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 20 };
    private readonly HashSet<int> pressed = new();
    private readonly SynchronizationContext ui;
    private IntPtr hook;
    private Mods held;
    private HotkeyRecorder? recorder;
    private bool winUsedForDictation;

    public event Action? Down;
    public event Action? Up;
    public event Action? Abort;
    public event Action<HotkeyTrigger?>? Recorded;

    public bool Installed => hook != IntPtr.Zero;

    public KeyboardHook(IReadOnlyList<HotkeyTrigger> triggers)
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        matcher = new HotkeyMatcher(triggers);
        proc = Callback;
        timer.Tick += (_, _) => Tick();
    }

    public void Start()
    {
        if (hook != IntPtr.Zero) return;
        hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, proc, Native.GetModuleHandle(null), 0);
        timer.Start();
    }

    public void SetTriggers(IReadOnlyList<HotkeyTrigger> triggers)
    {
        matcher.Triggers = triggers;
        Emit(matcher.Reset(held));
    }

    public void StartRecording() { recorder = new HotkeyRecorder(); Emit(matcher.Reset(Mods.None)); }
    public void CancelRecording() { recorder = null; Emit(matcher.Reset(held)); }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        var data = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
        // Lo que publica la propia app (Ctrl+V, tecla de relleno) no es una pulsación física.
        if ((data.flags & Native.LLKHF_INJECTED) != 0) return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        int msg = wParam.ToInt32();
        bool down = msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN;
        bool up = msg == Native.WM_KEYUP || msg == Native.WM_SYSKEYUP;
        int vk = (int)data.vkCode;
        double now = clock.Elapsed.TotalSeconds;

        // AltGr envía un Ctrl izquierdo ficticio (código de exploración 0x21D) antes de Alt derecho.
        if (vk == 0xA2 && data.scanCode == 0x21D) return Native.CallNextHookEx(hook, nCode, wParam, lParam);

        var mod = ModKeys.FromVk(vk);
        if (mod != Mods.None)
        {
            bool wasDown = (held & mod) != 0;
            held = down ? held | mod : held & ~mod;
            if (down && wasDown) return Native.CallNextHookEx(hook, nCode, wParam, lParam);
            if (recorder is not null)
            {
                var trigger = recorder.ModifiersChanged(held);
                if (trigger is not null) FinishRecording(trigger);
                return Native.CallNextHookEx(hook, nCode, wParam, lParam);
            }
            if (up && (mod == Mods.LWin || mod == Mods.RWin) && winUsedForDictation)
            {
                winUsedForDictation = false;
                Native.SendKeys(((ushort)DummyVk, false), ((ushort)DummyVk, true));
            }
            Emit(matcher.ModifiersChanged(held, now));
            return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        }

        if (recorder is not null)
        {
            if (down && !pressed.Contains(vk))
            {
                if (vk == 0x1B && held == Mods.None) FinishRecording(null);
                else FinishRecording(recorder.KeyDown(vk, held));
            }
            if (down) pressed.Add(vk); else pressed.Remove(vk);
            return (IntPtr)1;
        }

        bool consume = false;
        if (down)
        {
            bool repeat = !pressed.Add(vk);
            var (outputs, c) = matcher.KeyDown(vk, repeat, now);
            Emit(outputs);
            consume = c;
        }
        else if (up)
        {
            pressed.Remove(vk);
            var (outputs, c) = matcher.KeyUp(vk);
            Emit(outputs);
            consume = c;
        }
        return consume ? (IntPtr)1 : Native.CallNextHookEx(hook, nCode, wParam, lParam);
    }

    private void Tick()
    {
        if (recorder is not null) return;
        double now = clock.Elapsed.TotalSeconds;
        // Conciliación de liberaciones perdidas: nunca empieza una pulsación, solo la termina.
        var physical = Mods.None;
        foreach (var info in ModKeys.All) if (Native.IsDown(info.Vk)) physical |= info.Mod;
        if ((held & ~physical) != Mods.None)
        {
            held &= physical;
            Emit(matcher.ModifiersChanged(held, now));
        }
        if (matcher.SwallowedKey is int key && !Native.IsDown(key)) Emit(matcher.KeyUp(key).Outputs);
        Emit(matcher.Tick(now));
    }

    private void FinishRecording(HotkeyTrigger? trigger)
    {
        recorder = null;
        Emit(matcher.Reset(held));
        ui.Post(_ => Recorded?.Invoke(trigger), null);
    }

    private void Emit(List<HotkeyOutput> outputs)
    {
        foreach (var output in outputs)
        {
            if (output == HotkeyOutput.Down && matcher.Active is HotkeyTrigger active
                && (active.Modifiers & (Mods.LWin | Mods.RWin)) != Mods.None) winUsedForDictation = true;
            // Fuera del gancho: Windows lo retira si tarda en responder.
            var handler = output switch { HotkeyOutput.Down => Down, HotkeyOutput.Up => Up, _ => Abort };
            ui.Post(_ => handler?.Invoke(), null);
        }
    }

    public void Dispose()
    {
        timer.Stop();
        if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }
}
