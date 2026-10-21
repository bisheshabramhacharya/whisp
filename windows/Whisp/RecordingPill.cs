using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using Whisp.Core;

namespace Whisp;

/// <summary>
/// The floating recording pill, matching the Mac design: a near-black capsule showing
/// the icon of the app you're typing into, nine white bars while you talk, a thin
/// spinner while it transcribes, and a small lock in hands-free mode. Dimmed while
/// idle (when "Always Show" is on) so it can be dragged anywhere; remembers where it
/// was left. Never takes focus.
/// </summary>
internal sealed class RecordingPill : Form
{
    private const float BaseWidth = 180, BaseHeight = 50.4f;
    private const int BarCount = 9;

    private readonly AppSettings _settings;
    private readonly System.Windows.Forms.Timer _frame = new() { Interval = 33 };
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly float[] _bars = new float[BarCount];
    private readonly Dictionary<string, Bitmap?> _iconCache = new();
    private float _level;
    private DictationState _state = DictationState.Idle;
    private bool _handsFree;
    private bool _loading;
    private Bitmap? _appIcon;
    private Point? _dragOffset;
    private Point _origin;

    public event Action<Point>? ContextMenuRequested;

    public RecordingPill(AppSettings settings)
    {
        _settings = settings;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Text = "Whisp";
        _frame.Tick += (_, _) => Render();
        _settings.Changed += () =>
        {
            if (IsHandleCreated) BeginInvoke(() => { PlaceAtSavedOrigin(); UpdateVisibility(); });
        };
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        PlaceAtSavedOrigin();
        Render();
    }

    private float PillFactor => (float)_settings.PillScale * DeviceDpi / 96f;
    private Size PillSize => new((int)Math.Round(BaseWidth * PillFactor), (int)Math.Round(BaseHeight * PillFactor));

    public void SetState(DictationState state, bool handsFree, bool loading)
    {
        if (state == DictationState.Recording && _state != DictationState.Recording) _appIcon = ForegroundAppIcon();
        _state = state;
        _handsFree = handsFree;
        _loading = loading;
        if (state != DictationState.Recording) _level = 0;
        UpdateVisibility();
    }

    public void PushLevel(float level) => _level = level;

    public void UpdateVisibility()
    {
        var active = _state != DictationState.Idle;
        var visible = active || _settings.AlwaysShowPill;
        if (visible && !Visible) Show();
        if (!visible && Visible) Hide();
        _frame.Enabled = visible && active;
        if (visible) Render();
    }

    private void PlaceAtSavedOrigin()
    {
        var size = PillSize;
        if (_settings.PillOrigin is { } o)
        {
            var p = new Point((int)o.X, (int)o.Y);
            // Keep it reachable if the monitor it was on is gone.
            if (Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(new Rectangle(p, size))))
            {
                _origin = p;
                return;
            }
        }
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        _origin = new Point(area.Left + (area.Width - size.Width) / 2, area.Bottom - size.Height - (int)(24 * DeviceDpi / 96f));
    }

    // Drawing

    private void Render()
    {
        if (!IsHandleCreated) return;
        var size = PillSize;
        using var bitmap = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(Color.Transparent);
            Draw(g, size);
        }
        Present(bitmap);
    }

    private void Draw(Graphics g, Size size)
    {
        var idle = _state == DictationState.Idle;
        float w = size.Width, h = size.Height, r = h / 2;
        using (var capsule = Capsule(new RectangleF(0.5f, 0.5f, w - 1, h - 1)))
        {
            using var fill = new SolidBrush(Color.FromArgb(idle ? 150 : 240, 16, 16, 18));
            g.FillPath(fill, capsule);
            using var edge = new Pen(Color.FromArgb(idle ? 40 : 60, 255, 255, 255), Math.Max(1, PillFactor * 0.75f));
            g.DrawPath(edge, capsule);
        }

        var contentLeft = r * 0.75f;
        var contentRight = w - r * 0.75f;
        if (!idle && _appIcon != null)
        {
            var iconSize = h * 0.5f;
            g.DrawImage(_appIcon, contentLeft, (h - iconSize) / 2, iconSize, iconSize);
            contentLeft += iconSize + h * 0.2f;
        }
        if (_handsFree)
        {
            DrawLock(g, contentRight - h * 0.3f, h / 2, h * 0.3f);
            contentRight -= h * 0.45f;
        }

        var t = (float)_clock.Elapsed.TotalSeconds;
        if (_state == DictationState.Transcribing || (_state == DictationState.Recording && _loading))
        {
            DrawSpinner(g, (contentLeft + contentRight) / 2, h / 2, h * 0.22f, t);
            return;
        }

        // Bars: louder in the middle, rolling outward from the center while you talk.
        for (var i = 0; i < BarCount; i++)
        {
            var fromCenter = Math.Abs(i - (BarCount - 1) / 2f) / ((BarCount - 1) / 2f);
            var target = idle ? 0 : _level * (1 - 0.55f * fromCenter) * (0.75f + 0.25f * MathF.Sin(t * 9 + i * 1.3f));
            _bars[i] += (target - _bars[i]) * (target > _bars[i] ? 0.6f : 0.25f);
        }
        var span = contentRight - contentLeft;
        var barWidth = Math.Max(1.5f, h * 0.075f);
        var gap = (span - barWidth * BarCount) / (BarCount - 1);
        gap = Math.Min(gap, barWidth * 1.8f);
        var total = barWidth * BarCount + gap * (BarCount - 1);
        var x = contentLeft + (span - total) / 2;
        using var brush = new SolidBrush(Color.FromArgb(idle ? 110 : 255, 255, 255, 255));
        for (var i = 0; i < BarCount; i++)
        {
            var barHeight = Math.Max(barWidth, h * 0.55f * _bars[i]);
            using var bar = Capsule(new RectangleF(x, (h - barHeight) / 2, barWidth, barHeight));
            g.FillPath(brush, bar);
            x += barWidth + gap;
        }
    }

    private void DrawSpinner(Graphics g, float cx, float cy, float radius, float t)
    {
        using var track = new Pen(Color.FromArgb(60, 255, 255, 255), Math.Max(1.5f, radius * 0.22f));
        using var arc = new Pen(Color.White, Math.Max(1.5f, radius * 0.22f)) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        var rect = new RectangleF(cx - radius, cy - radius, radius * 2, radius * 2);
        g.DrawEllipse(track, rect);
        g.DrawArc(arc, rect, t * 360 % 360, 90);
    }

    private void DrawLock(Graphics g, float cx, float cy, float size)
    {
        using var brush = new SolidBrush(Color.FromArgb(230, 255, 255, 255));
        using var pen = new Pen(brush, Math.Max(1.2f, size * 0.14f));
        var body = new RectangleF(cx - size * 0.5f, cy - size * 0.1f, size, size * 0.75f);
        using (var path = Capsule(body, size * 0.15f)) g.FillPath(brush, path);
        g.DrawArc(pen, cx - size * 0.32f, cy - size * 0.6f, size * 0.64f, size * 0.9f, 180, 180);
    }

    private static GraphicsPath Capsule(RectangleF rect, float? radius = null)
    {
        var r = Math.Min(radius ?? rect.Height / 2, Math.Min(rect.Width, rect.Height) / 2);
        var path = new GraphicsPath();
        if (r <= 0)
        {
            path.AddRectangle(rect);
            return path;
        }
        var d = r * 2;
        path.AddArc(rect.Left, rect.Top, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Top, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    private void Present(Bitmap bitmap)
    {
        var screenDc = Native.GetDC(IntPtr.Zero);
        var memDc = Native.CreateCompatibleDC(screenDc);
        var hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
        var old = Native.SelectObject(memDc, hBitmap);
        try
        {
            var size = new Native.SIZE(bitmap.Width, bitmap.Height);
            var source = new Native.POINT(0, 0);
            var dest = new Native.POINT(_origin.X, _origin.Y);
            var blend = new Native.BLENDFUNCTION { SourceConstantAlpha = 255, AlphaFormat = Native.AC_SRC_ALPHA };
            Native.UpdateLayeredWindow(Handle, screenDc, ref dest, ref size, memDc, ref source, 0, ref blend, Native.ULW_ALPHA);
        }
        finally
        {
            Native.SelectObject(memDc, old);
            Native.DeleteObject(hBitmap);
            Native.DeleteDC(memDc);
            Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    // App icon

    private Bitmap? ForegroundAppIcon()
    {
        try
        {
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
            using var process = Process.GetProcessById((int)pid);
            var path = process.MainModule?.FileName;
            if (path == null) return null;
            if (!_iconCache.TryGetValue(path, out var icon))
            {
                using var extracted = Icon.ExtractAssociatedIcon(path);
                icon = extracted == null ? null : new Icon(extracted, 64, 64).ToBitmap();
                _iconCache[path] = icon;
            }
            return icon;
        }
        catch (Exception)
        {
            // Elevated or protected processes can't be inspected; show no icon.
            return null;
        }
    }

    // Dragging

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left) _dragOffset = new Point(Cursor.Position.X - _origin.X, Cursor.Position.Y - _origin.Y);
        if (e.Button == MouseButtons.Right) ContextMenuRequested?.Invoke(Cursor.Position);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_dragOffset is not { } offset) return;
        _origin = new Point(Cursor.Position.X - offset.X, Cursor.Position.Y - offset.Y);
        Render();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (_dragOffset == null) return;
        _dragOffset = null;
        _settings.PillOrigin = (_origin.X, _origin.Y);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Render();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _frame.Dispose();
            foreach (var icon in _iconCache.Values) icon?.Dispose();
        }
        base.Dispose(disposing);
    }
}
