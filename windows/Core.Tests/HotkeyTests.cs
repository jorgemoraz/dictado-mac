using Dictado.Core;
using Xunit;

public class HotkeyTests
{
    static readonly Mods CtrlAlt = Mods.LCtrl | Mods.LAlt;

    [Fact]
    public void CtrlAltEsperaYEmpieza()
    {
        var m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        Assert.Empty(m.ModifiersChanged(Mods.LCtrl, 0));
        Assert.Empty(m.ModifiersChanged(CtrlAlt, 0.02));
        Assert.Empty(m.Tick(0.10));
        Assert.Equal(new[] { HotkeyOutput.Down }, m.Tick(0.18));
        Assert.Equal(new[] { HotkeyOutput.Up }, m.ModifiersChanged(Mods.LAlt, 3));
        Assert.Empty(m.ModifiersChanged(CtrlAlt, 3.1));
        Assert.Empty(m.Tick(3.5));
        Assert.Empty(m.ModifiersChanged(Mods.None, 4));
    }

    [Fact]
    public void CtrlWinEmpiezaYTermina()
    {
        var m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(Mods.LCtrl, 0);
        m.ModifiersChanged(Mods.LCtrl | Mods.LWin, 0.05);
        Assert.Equal(new[] { HotkeyOutput.Down }, m.Tick(0.3));
        Assert.Equal(new[] { HotkeyOutput.Up }, m.ModifiersChanged(Mods.LCtrl, 2));
    }

    [Fact]
    public void LadoDerechoNoActiva()
    {
        var m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(Mods.RCtrl | Mods.RAlt, 0);
        Assert.Empty(m.Tick(1));
    }

    [Fact]
    public void OtroAtajoRapidoNoDicta()
    {
        var m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(CtrlAlt, 0);
        var (outputs, consume) = m.KeyDown(0x20, false, 0.05);
        Assert.Empty(outputs);
        Assert.False(consume);
        Assert.Empty(m.Tick(1));
    }

    [Fact]
    public void TeclaNadaMasEmpezarDescartaYTardiaTermina()
    {
        var m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(CtrlAlt, 0); m.Tick(0.2);
        Assert.Equal(new[] { HotkeyOutput.Abort }, m.KeyDown(0x44, false, 0.4).Outputs);
        m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(CtrlAlt, 0); m.Tick(0.2);
        Assert.Equal(new[] { HotkeyOutput.Up }, m.KeyDown(0x44, false, 3).Outputs);
        m = new HotkeyMatcher(HotkeyTrigger.Defaults);
        m.ModifiersChanged(CtrlAlt, 0); m.Tick(0.2);
        Assert.Equal(new[] { HotkeyOutput.Abort }, m.ModifiersChanged(CtrlAlt | Mods.LShift, 0.3));
    }

    [Fact]
    public void AtajoConTeclaSeConsume()
    {
        var custom = new HotkeyTrigger(Mods.RAlt, 0x44);
        var m = new HotkeyMatcher(new[] { custom });
        m.ModifiersChanged(Mods.RAlt, 0);
        var down = m.KeyDown(0x44, false, 0.01);
        Assert.Equal(new[] { HotkeyOutput.Down }, down.Outputs);
        Assert.True(down.Consume);
        Assert.True(m.KeyDown(0x44, true, 0.5).Consume);
        Assert.Equal(HotkeyOutput.Up, m.ModifiersChanged(Mods.None, 1).Single());
        Assert.True(m.KeyDown(0x44, true, 1.1).Consume);
        Assert.True(m.KeyUp(0x44).Consume);
        Assert.Empty(m.KeyDown(0x44, false, 2).Outputs);
    }

    [Fact]
    public void TeclaFSola()
    {
        var f13 = new HotkeyTrigger(Mods.None, 0x7C);
        var m = new HotkeyMatcher(new[] { f13 });
        Assert.Equal(new[] { HotkeyOutput.Down }, m.KeyDown(0x7C, false, 0).Outputs);
        Assert.Equal(new[] { HotkeyOutput.Up }, m.KeyUp(0x7C).Outputs);
        Assert.Null(f13.Problem);
        Assert.NotNull(new HotkeyTrigger(Mods.None, 0x44).Problem);
        Assert.Equal("F13", f13.Label());
    }

    [Fact]
    public void Grabacion()
    {
        var r = new HotkeyRecorder();
        r.ModifiersChanged(Mods.LCtrl);
        r.ModifiersChanged(CtrlAlt);
        r.ModifiersChanged(Mods.LAlt);
        Assert.Equal(HotkeyTrigger.CtrlAlt, r.ModifiersChanged(Mods.None));
        Assert.Equal(new HotkeyTrigger(Mods.RAlt, 0x44), r.KeyDown(0x44, Mods.RAlt));
        Assert.Equal("Ctrl izq. + Alt izq.", HotkeyTrigger.CtrlAlt.Label());
    }
}
