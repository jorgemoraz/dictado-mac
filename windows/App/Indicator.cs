using System.Drawing.Drawing2D;

namespace Dictado;

/// <summary>Indicador flotante: no roba el foco ni recibe clics.</summary>
internal sealed class IndicatorForm : Form
{
    private string title = "Escuchando";
    private float level;

    public IndicatorForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        Size = new Size(320, 64);
        DoubleBuffered = true;
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008 | 0x00000020; // NOACTIVATE, TOOLWINDOW, TOPMOST, TRANSPARENT
            return cp;
        }
    }

    public void ShowState(string text)
    {
        title = text;
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 24);
        if (!Visible) Show();
        Invalidate();
    }

    public void SetLevel(float value) { level = value; if (Visible) Invalidate(); }

    public void HideIndicator() { level = 0; Hide(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = new GraphicsPath();
        var r = new Rectangle(0, 0, Width - 1, Height - 1);
        int radius = 22;
        path.AddArc(r.X, r.Y, radius * 2, radius * 2, 180, 90);
        path.AddArc(r.Right - radius * 2, r.Y, radius * 2, radius * 2, 270, 90);
        path.AddArc(r.Right - radius * 2, r.Bottom - radius * 2, radius * 2, radius * 2, 0, 90);
        path.AddArc(r.X, r.Bottom - radius * 2, radius * 2, radius * 2, 90, 90);
        path.CloseFigure();
        using (var background = new SolidBrush(Color.FromArgb(235, 18, 18, 20))) g.FillPath(background, path);
        var dot = title.StartsWith("Escuchando") ? Color.FromArgb(255, 69, 58) : Color.FromArgb(255, 159, 10);
        using (var brush = new SolidBrush(dot)) g.FillEllipse(brush, 22, Height / 2 - 5, 10, 10);
        using (var font = new Font("Segoe UI Semibold", 11f))
            TextRenderer.DrawText(g, title, font, new Point(42, Height / 2 - 11), Color.White);
        int[] heights = { 14, 26, 35, 26, 14 };
        for (int i = 0; i < heights.Length; i++)
        {
            int h = 5 + (int)(level * heights[i]);
            using var bar = new SolidBrush(Color.FromArgb(210, 255, 255, 255));
            g.FillRectangle(bar, Width - 60 + i * 7, Height / 2 - h / 2, 3, h);
        }
    }
}
