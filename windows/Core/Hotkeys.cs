namespace Dictado.Core;

/// <summary>Teclas modificadoras, distinguiendo izquierda y derecha.</summary>
[Flags]
public enum Mods : ushort
{
    None = 0,
    LCtrl = 1, RCtrl = 2,
    LAlt = 4, RAlt = 8,
    LShift = 16, RShift = 32,
    LWin = 64, RWin = 128,
}

public static class ModKeys
{
    public sealed record Info(Mods Mod, string Label, int Vk);

    /// <summary>Orden de presentación y código virtual (VK) de cada modificadora.</summary>
    public static readonly Info[] All =
    {
        new(Mods.LCtrl, "Ctrl izq.", 0xA2), new(Mods.RCtrl, "Ctrl dcha.", 0xA3),
        new(Mods.LWin, "Win izq.", 0x5B), new(Mods.RWin, "Win dcha.", 0x5C),
        new(Mods.LAlt, "Alt izq.", 0xA4), new(Mods.RAlt, "Alt dcha.", 0xA5),
        new(Mods.LShift, "Mayús izq.", 0xA0), new(Mods.RShift, "Mayús dcha.", 0xA1),
    };

    /// <summary>Modificadora de un código virtual; los genéricos (Ctrl, Alt, Mayús) cuentan como izquierdos.</summary>
    public static Mods FromVk(int vk) => vk switch
    {
        0x11 => Mods.LCtrl,
        0x12 => Mods.LAlt,
        0x10 => Mods.LShift,
        _ => All.FirstOrDefault(i => i.Vk == vk)?.Mod ?? Mods.None,
    };

    public static bool IsModifier(int vk) => FromVk(vk) != Mods.None;
}

public static class KeyNames
{
    public static string Name(int vk)
    {
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x70 && vk <= 0x87) return $"F{vk - 0x6F}";
        return vk switch
        {
            0x20 => "Espacio", 0x0D => "Intro", 0x09 => "Tab", 0x08 => "Retroceso", 0x2E => "Supr",
            0x1B => "Esc", 0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓",
            0x24 => "Inicio", 0x23 => "Fin", 0x21 => "RePág", 0x22 => "AvPág", 0x2D => "Insert",
            0x13 => "Pausa", 0x91 => "Bloq Despl", 0x2C => "Impr Pant",
            _ => $"Tecla {vk:X2}",
        };
    }
}

/// <summary>Atajo para dictar mientras se mantiene pulsado.</summary>
public sealed record HotkeyTrigger(Mods Modifiers, int? Key)
{
    public bool IsModifierOnly => Key is null;

    public static readonly HotkeyTrigger CtrlWin = new(Mods.LCtrl | Mods.LWin, null);
    public static readonly HotkeyTrigger CtrlAlt = new(Mods.LCtrl | Mods.LAlt, null);
    public static IReadOnlyList<HotkeyTrigger> Defaults => new[] { CtrlWin, CtrlAlt };

    public static bool IsFunctionKey(int vk) => vk >= 0x70 && vk <= 0x87;

    public string Label(Func<int, string>? keyName = null)
    {
        var parts = ModKeys.All.Where(i => Modifiers.HasFlag(i.Mod)).Select(i => i.Label).ToList();
        if (Key is int key) parts.Add((keyName ?? KeyNames.Name)(key));
        return string.Join(" + ", parts);
    }

    /// <summary>Motivo por el que no conviene usar este atajo, o null si es válido.</summary>
    public string? Problem
    {
        get
        {
            if (Modifiers == Mods.None && Key is null) return "No se ha detectado ninguna tecla.";
            if (Key is int key && Modifiers == Mods.None && !IsFunctionKey(key))
                return "Una tecla normal sola dejaría de escribirse. Combínala con una modificadora o usa una tecla F.";
            return null;
        }
    }
}

public enum HotkeyOutput { Down, Up, Abort }

/// <summary>
/// Lógica pura de «mantener para dictar», igual que en Dictado Mac.
/// Las combinaciones solo de modificadoras esperan un instante para no chocar con
/// otros atajos; una tecla pulsada justo después de empezar descarta el dictado.
/// </summary>
public sealed class HotkeyMatcher
{
    public const double ArmDelay = 0.15;
    public const double AbortWindow = 0.6;

    public IReadOnlyList<HotkeyTrigger> Triggers { get; set; }
    public Mods Held { get; private set; }
    public HotkeyTrigger? Active { get; private set; }
    public int? SwallowedKey { get; private set; }
    private double activeSince;
    private HotkeyTrigger? pending;
    private double pendingSince;
    private bool blocked;

    public HotkeyMatcher(IReadOnlyList<HotkeyTrigger> triggers) => Triggers = triggers;

    public List<HotkeyOutput> Reset(Mods held)
    {
        var output = Active is not null ? new List<HotkeyOutput> { HotkeyOutput.Up } : new List<HotkeyOutput>();
        Active = null;
        pending = null;
        SwallowedKey = null;
        Held = held;
        blocked = held != Mods.None;
        return output;
    }

    public List<HotkeyOutput> ModifiersChanged(Mods newHeld, double time)
    {
        Held = newHeld;
        pending = null;
        if (Active is HotkeyTrigger current)
        {
            if (newHeld == current.Modifiers) return new();
            Active = null;
            blocked = newHeld != Mods.None;
            bool added = (newHeld & current.Modifiers) == current.Modifiers && newHeld != current.Modifiers;
            return new() { added ? ChordEnd(time) : HotkeyOutput.Up };
        }
        if (newHeld == Mods.None) { blocked = false; return new(); }
        if (blocked) return new();
        var match = Triggers.FirstOrDefault(t => t.IsModifierOnly && t.Modifiers == newHeld);
        if (match is null) return new();
        pending = match;
        pendingSince = time;
        return new();
    }

    public List<HotkeyOutput> Tick(double time)
    {
        if (pending is not HotkeyTrigger candidate || blocked || Held != candidate.Modifiers
            || time - pendingSince < ArmDelay) return new();
        pending = null;
        return Activate(candidate, time);
    }

    /// <summary>Transiciones y si la pulsación debe consumirse.</summary>
    public (List<HotkeyOutput> Outputs, bool Consume) KeyDown(int key, bool isRepeat, double time)
    {
        if (SwallowedKey == key) return (new(), true);
        if (Active is not null)
        {
            Active = null;
            blocked = Held != Mods.None;
            return (new() { ChordEnd(time) }, false);
        }
        if (pending is not null)
        {
            pending = null;
            blocked = true;
            return (new(), false);
        }
        if (isRepeat) return (new(), false);
        var match = Triggers.FirstOrDefault(t => t.Key == key && t.Modifiers == Held);
        if (match is null) return (new(), false);
        SwallowedKey = key;
        return (Activate(match, time), true);
    }

    public (List<HotkeyOutput> Outputs, bool Consume) KeyUp(int key)
    {
        if (SwallowedKey != key) return (new(), false);
        SwallowedKey = null;
        if (Active is HotkeyTrigger current && current.Key == key)
        {
            Active = null;
            blocked = Held != Mods.None;
            return (new() { HotkeyOutput.Up }, true);
        }
        return (new(), true);
    }

    private List<HotkeyOutput> Activate(HotkeyTrigger trigger, double time)
    {
        Active = trigger;
        activeSince = time;
        return new() { HotkeyOutput.Down };
    }

    private HotkeyOutput ChordEnd(double time) => time - activeSince < AbortWindow ? HotkeyOutput.Abort : HotkeyOutput.Up;
}

/// <summary>Graba una combinación: la tecla normal pulsada o el máximo de modificadoras al soltarlas.</summary>
public sealed class HotkeyRecorder
{
    public Mods Peak { get; private set; }

    public HotkeyTrigger? ModifiersChanged(Mods held)
    {
        if (held == Mods.None)
        {
            var result = Peak == Mods.None ? null : new HotkeyTrigger(Peak, null);
            Peak = Mods.None;
            return result;
        }
        Peak |= held;
        return null;
    }

    public HotkeyTrigger KeyDown(int key, Mods held)
    {
        Peak = Mods.None;
        return new HotkeyTrigger(held, key);
    }
}
