using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using WF = System.Windows.Forms;

namespace JarvisHUD;

static class Program {
    [STAThread]
    static void Main() {
        using var mutex = new Mutex(true, "JarvisHUD.single", out bool first);
        if (!first) { WF.MessageBox.Show("JarvisHUD is already running (look for the ◎ icon in the tray).", "JarvisHUD"); return; }
        var app = new App(); app.Run();
    }
}

sealed class App : Application {
    public static readonly Color Cyan = Color.FromRgb(51, 217, 255);
    public static readonly Brush CyanBrush = new SolidColorBrush(Cyan);
    public static readonly Brush DimBrush = new SolidColorBrush(Color.FromArgb(90, 51, 217, 255));
    WF.NotifyIcon tray = null!;
    HudWindow? hud; OverlayWindow? overlay;
    HotkeyWindow hot = null!;

    protected override void OnStartup(StartupEventArgs e) {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        Memory.Prune();
        Log.V("launch " + Doctor.OsVersion);
        tray = new WF.NotifyIcon { Icon = LoadIcon(), Visible = true, Text = "JARVIS — Alt+Space" };
        tray.MouseClick += (_, ev) => { if (ev.Button == WF.MouseButtons.Left) ToggleHud(); };
        BuildMenu();
        hot = new HotkeyWindow(); hot.OnToggleHud = ToggleHud; hot.OnToggleOverlay = ToggleOverlay;
        if (!hot.Register()) tray.ShowBalloonTip(4000, "JARVIS", "Alt+Space is taken by another app; using Win+J instead.", WF.ToolTipIcon.Info);
        AI.OnConfirm = q => Dispatcher.InvokeAsync(() => Hud.Confirm(q)).Task.Unwrap();
        AI.OnStatus = s => Dispatcher.InvokeAsync(() => hud?.SetStatus(s));
        AI.OnStep = s => Dispatcher.InvokeAsync(() => hud?.AppendStep(s));
        Agent.OnScanStatus = s => Dispatcher.InvokeAsync(() => hud?.SetStatus(s));
        Voice.Shared.OnCommand = q => Dispatcher.InvokeAsync(() => { AI.Spoken = true; Hud.ShowAndAsk(q); });
        Voice.Shared.OnState = s => Dispatcher.InvokeAsync(() => { if (hud != null && !hud.Busy) hud.SetStatus(s); });
        if (Voice.Enabled) { var err = Voice.Shared.Start(); if (err.Length > 0) { Voice.Enabled = false; tray.ShowBalloonTip(6000, "JARVIS wake word", err, WF.ToolTipIcon.Warning); } }
        Guard.Watcher.Shared.OnResult = (file, verdict, detail) => Dispatcher.InvokeAsync(() => DownloadChecked(file, verdict, detail));
        if (Settings.GetBool("watchDownloads", true)) Guard.Watcher.Shared.Start();
        if (!Settings.Has("aiKey")) { Hud.Show(); Hud.AppendLine("Good day, sir. Right-click the tray icon ◎ → AI Provider… to give me a brain (an API key), then press Alt+Space whenever you need me."); }
    }
    static System.Drawing.Icon LoadIcon() {
        try { var p = System.IO.Path.Combine(AppContext.BaseDirectory, "AppIcon.ico"); if (File.Exists(p)) return new System.Drawing.Icon(p, 32, 32); } catch { }
        try { var ic = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!); if (ic != null) return ic; } catch { }
        var bmp = new System.Drawing.Bitmap(32, 32); using (var g = System.Drawing.Graphics.FromImage(bmp)) { g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; using var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(51, 217, 255), 3); g.DrawEllipse(pen, 3, 3, 26, 26); g.DrawEllipse(pen, 10, 10, 12, 12); }
        return System.Drawing.Icon.FromHandle(bmp.GetHicon());
    }
    HudWindow Hud { get { if (hud == null) { hud = new HudWindow(); hud.Closed += (_, _) => hud = null; } return hud; } }
    void ToggleHud() { if (hud != null && hud.IsVisible) hud.HideHud(); else Hud.Show(); }
    void ToggleOverlay() { if (overlay != null) { overlay.Close(); overlay = null; } else { overlay = new OverlayWindow(); overlay.Closed += (_, _) => overlay = null; overlay.Show(); } }

    void BuildMenu() {
        var m = new WF.ContextMenuStrip();
        m.Items.Add("Open JARVIS\tAlt+Space", null, (_, _) => ToggleHud());
        m.Items.Add("Stats Overlay\tCtrl+Alt+Space", null, (_, _) => ToggleOverlay());
        m.Items.Add(new WF.ToolStripSeparator());
        m.Items.Add($"AI Provider…  ({AI.ProviderName} / {AI.Model})", null, (_, _) => { new ProviderDialog().ShowDialog(); BuildMenu(); });
        m.Items.Add($"Web Search…  ({Search.Provider})", null, (_, _) => { new SearchDialog().ShowDialog(); BuildMenu(); });
        m.Items.Add($"VirusTotal Key…  ({(Guard.VtKey.Length > 0 ? "set" : "not set")})", null, (_, _) => { new KeyDialog("VirusTotal API key", "Only used when a download or program looks sketchy. Free key: virustotal.com → sign up → API key (4 lookups/min).", Guard.VtKey, v => Guard.VtKey = v).ShowDialog(); BuildMenu(); });
        m.Items.Add(new WF.ToolStripSeparator());
        var voice = new WF.ToolStripMenuItem("Wake Word  (say \"Jarvis, …\")") { Checked = Voice.Enabled && Voice.Shared.Running };
        voice.Click += (_, _) => {
            if (Voice.Shared.Running) { Voice.Shared.Stop(); Voice.Enabled = false; }
            else { var err = Voice.Shared.Start(); if (err.Length > 0) WF.MessageBox.Show(err, "Wake word"); else Voice.Enabled = true; }
            BuildMenu();
        };
        m.Items.Add(voice);
        var langs = new WF.ToolStripMenuItem("Wake Word Languages");
        var installed = Voice.Installed; var sel = Voice.Selected;
        foreach (var l in Voice.Languages) {
            var inst = installed.Contains(l.id);
            var it = new WF.ToolStripMenuItem($"{l.name}  ({l.id}){(inst ? "" : "  — not installed in Windows")}") { Checked = sel.Contains(l.id), Enabled = inst };
            it.Click += (_, _) => { var s = Voice.Selected; if (s.Contains(l.id)) s.Remove(l.id); else s.Add(l.id); Voice.Selected = s; if (Voice.Shared.Running) Voice.Shared.Start(); BuildMenu(); };
            langs.DropDownItems.Add(it);
        }
        foreach (var id in installed.Where(i => !Voice.Languages.Any(l => l.id == i))) {
            var it = new WF.ToolStripMenuItem($"{id}  (wake word: jarvis)") { Checked = sel.Contains(id) };
            it.Click += (_, _) => { var s = Voice.Selected; if (s.Contains(id)) s.Remove(id); else s.Add(id); Voice.Selected = s; if (Voice.Shared.Running) Voice.Shared.Start(); BuildMenu(); };
            langs.DropDownItems.Add(it);
        }
        langs.DropDownItems.Add(new WF.ToolStripSeparator());
        langs.DropDownItems.Add("Add a language to Windows…", null, (_, _) => Open("ms-settings:speech"));
        m.Items.Add(langs);
        var watch = new WF.ToolStripMenuItem("Check New Downloads Automatically") { Checked = Guard.Watcher.Shared.Running };
        watch.Click += (_, _) => { if (Guard.Watcher.Shared.Running) { Guard.Watcher.Shared.Stop(); Settings.Set("watchDownloads", false); } else { Guard.Watcher.Shared.Start(); Settings.Set("watchDownloads", true); } BuildMenu(); };
        m.Items.Add(watch);
        var confirm = new WF.ToolStripMenuItem("Confirm Risky Actions") { Checked = Agent.ConfirmActions };
        confirm.Click += (_, _) => { Agent.ConfirmActions = !Agent.ConfirmActions; BuildMenu(); };
        m.Items.Add(confirm);
        m.Items.Add(new WF.ToolStripSeparator());
        m.Items.Add("Clean Up Disk…", null, (_, _) => Hud.ShowAndAsk("Clean up my disk: scan the drive first, then tell me what is safe to clean, what would make something slower, and what you will not touch."));
        m.Items.Add("Scan for Malware…", null, (_, _) => Hud.ShowAndAsk("Scan this PC for malware and tell me what you find."));
        m.Items.Add("How Is My PC Doing?", null, (_, _) => Hud.ShowAndAsk("Run a diagnosis and tell me how this PC is doing right now."));
        m.Items.Add(new WF.ToolStripSeparator());
        m.Items.Add("Clear Conversation", null, (_, _) => { AI.ClearHistory(); hud?.ClearOutput(); });
        m.Items.Add("Forget Today's Transcript", null, (_, _) => Memory.ForgetToday());
        m.Items.Add("Forget Everything Heard", null, (_, _) => { if (WF.MessageBox.Show("Delete all 14 days of heard transcripts?", "JARVIS", WF.MessageBoxButtons.YesNo) == WF.DialogResult.Yes) Memory.ForgetAllHeard(); });
        m.Items.Add("Open Memory Folder", null, (_, _) => Open(Memory.Dir));
        m.Items.Add("Open Quarantine Folder", null, (_, _) => { Directory.CreateDirectory(Guard.QuarantineDir); Open(Guard.QuarantineDir); });
        var login = new WF.ToolStripMenuItem("Start with Windows") { Checked = StartupEnabled };
        login.Click += (_, _) => { StartupEnabled = !StartupEnabled; BuildMenu(); };
        m.Items.Add(login);
        m.Items.Add(new WF.ToolStripSeparator());
        m.Items.Add("About JarvisHUD…", null, (_, _) => Open("https://github.com/tobyyu913/JarvisHUD"));
        m.Items.Add("Quit", null, (_, _) => { tray.Visible = false; Voice.Shared.Stop(); Guard.Watcher.Shared.Stop(); Shutdown(); });
        tray.ContextMenuStrip = m;
    }
    static void Open(string t) { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(t) { UseShellExecute = true }); } catch { } }
    static bool StartupEnabled {
        get { using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return k?.GetValue("JarvisHUD") != null; }
        set { using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (value) k.SetValue("JarvisHUD", $"\"{Environment.ProcessPath}\""); else k.DeleteValue("JarvisHUD", false); }
    }
    void DownloadChecked(string file, string verdict, string detail) {
        Log.V($"download {verdict}: {file}");
        var h = Hud; h.Show();
        h.AppendLine($"◎ New download vetted: {System.IO.Path.GetFileName(file)} — {verdict}");
        if (verdict == "PASS") { h.AppendLine(detail.Split('\n').Skip(1).FirstOrDefault(l => l.Contains("signed")) ?? "Signed and clean."); return; }
        h.Ask($"(Automatic download check, not typed by the user.) A file just finished downloading and I vetted it:\n{detail}\nFile: {file}\nTell the user in two or three sentences what this is, whether it is safe to open, and what to do (quarantine_item is available if it is clearly malicious; ask before using it).", quiet: true);
    }
}

/// Invisible window that owns the global hotkeys (Alt+Space, Ctrl+Alt+Space; fallback Win+J / Ctrl+Win+J).
sealed class HotkeyWindow : Window {
    public Action? OnToggleHud, OnToggleOverlay;
    const int WM_HOTKEY = 0x0312;
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    IntPtr handle;
    public HotkeyWindow() { Width = 0; Height = 0; WindowStyle = WindowStyle.None; ShowInTaskbar = false; ShowActivated = false; Opacity = 0; Show(); Hide(); handle = new WindowInteropHelper(this).EnsureHandle(); HwndSource.FromHwnd(handle)!.AddHook(Hook); }
    public bool Register() {
        bool ok = RegisterHotKey(handle, 1, 0x0001 /*ALT*/ | 0x4000 /*NOREPEAT*/, 0x20) && RegisterHotKey(handle, 2, 0x0001 | 0x0002 /*CTRL*/ | 0x4000, 0x20);
        if (!ok) { UnregisterHotKey(handle, 1); UnregisterHotKey(handle, 2); RegisterHotKey(handle, 1, 0x0008 /*WIN*/ | 0x4000, 0x4A); RegisterHotKey(handle, 2, 0x0008 | 0x0002 | 0x4000, 0x4A); }
        return ok;
    }
    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg == WM_HOTKEY) { if (wParam.ToInt32() == 1) OnToggleHud?.Invoke(); else if (wParam.ToInt32() == 2) OnToggleOverlay?.Invoke(); handled = true; }
        return IntPtr.Zero;
    }
}

/// The HUD: spinning rings top-right, a dark panel with the transcript and an input line. Enter sends, Esc closes.
sealed class HudWindow : Window {
    const double W = 540, H = 280, R = 70;
    readonly TextBox input = new(), output = new();
    readonly TextBlock status = new();
    readonly Canvas ringCanvas = new();
    public bool Busy;
    TaskCompletionSource<bool>? pendingConfirm;

    public HudWindow() {
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; ResizeMode = ResizeMode.NoResize;
        Topmost = true; ShowInTaskbar = false; Title = "J.A.R.V.I.S."; Width = W + R * 2 + 40; Height = H + 40;
        var wa = SystemParameters.WorkArea; Left = wa.Right - Width - 8; Top = wa.Top + 8;
        var root = new Grid(); Content = root;
        // panel
        var panel = new Border { Width = W, Height = H, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 20, 0, 0), CornerRadius = new CornerRadius(6), BorderBrush = App.CyanBrush, BorderThickness = new Thickness(1.5), Background = new SolidColorBrush(Color.FromArgb(205, 0, 31, 56)) };
        panel.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = App.Cyan, BlurRadius = 18, ShadowDepth = 0, Opacity = 0.6 };
        var g = new Grid { Margin = new Thickness(14, 10, 14, 12) };
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); g.RowDefinitions.Add(new RowDefinition()); g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var head = new DockPanel();
        var title = new TextBlock { Text = "J.A.R.V.I.S.", FontFamily = new FontFamily("Consolas"), FontSize = 18, FontWeight = FontWeights.Bold, Foreground = App.CyanBrush };
        status.FontFamily = new FontFamily("Consolas"); status.FontSize = 11; status.Foreground = App.DimBrush; status.VerticalAlignment = VerticalAlignment.Center; status.Margin = new Thickness(12, 4, 0, 0); status.Text = "READY";
        DockPanel.SetDock(title, Dock.Left); head.Children.Add(title); head.Children.Add(status);
        g.Children.Add(head);
        output.IsReadOnly = true; output.TextWrapping = TextWrapping.Wrap; output.Background = Brushes.Transparent; output.BorderThickness = new Thickness(0);
        output.Foreground = new SolidColorBrush(Color.FromRgb(178, 237, 255)); output.FontFamily = new FontFamily("Consolas"); output.FontSize = 13; output.Margin = new Thickness(0, 6, 0, 6);
        output.VerticalScrollBarVisibility = ScrollBarVisibility.Auto; output.IsTabStop = false; output.Focusable = true;
        Grid.SetRow(output, 1); g.Children.Add(output);
        input.FontFamily = new FontFamily("Consolas"); input.FontSize = 15; input.Foreground = Brushes.White; input.CaretBrush = App.CyanBrush;
        input.Background = new SolidColorBrush(Color.FromArgb(150, 0, 51, 90)); input.BorderBrush = App.DimBrush; input.BorderThickness = new Thickness(0, 0, 0, 1); input.Padding = new Thickness(6, 4, 6, 4);
        input.KeyDown += Input_KeyDown;
        Grid.SetRow(input, 2); g.Children.Add(input);
        panel.Child = g; root.Children.Add(panel);
        // rings
        ringCanvas.Width = R * 2; ringCanvas.Height = R * 2; ringCanvas.HorizontalAlignment = HorizontalAlignment.Right; ringCanvas.VerticalAlignment = VerticalAlignment.Top; ringCanvas.Margin = new Thickness(0, 20, 20, 0);
        ringCanvas.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = App.Cyan, BlurRadius = 14, ShadowDepth = 0, Opacity = 0.9 };
        Ring(R - 4, 2, App.CyanBrush, null, 0.72, 14); Ring(R - 16, 8, App.DimBrush, new DoubleCollection { 0.4, 1.0 }, 1, -30); Ring(R - 28, 3, App.CyanBrush, null, 0.25, 6); Ring(R - 42, 1.5, App.CyanBrush, new DoubleCollection { 9, 3 }, 1, -10);
        ringCanvas.Children.Add(new Ellipse { Width = (R - 56) * 2, Height = (R - 56) * 2, Fill = App.DimBrush, Margin = new Thickness(56) });
        root.Children.Add(ringCanvas);
        // restore the tail of the conversation
        var h = AI.History; if (h.Count > 0) { foreach (var t in h.Skip(Math.Max(0, h.Count - 8))) output.AppendText((t.role == "user" ? "> " : "") + t.text + "\n\n"); output.AppendText("— earlier conversation, still remembered —\n\n"); }
        Deactivated += (_, _) => { if (pendingConfirm == null && !Busy) HideHud(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { if (pendingConfirm != null) Resolve(false); else if (AI.Busy) AI.Stop(); else HideHud(); e.Handled = true; } };   // first Esc stops the reply, second closes
    }
    void Ring(double r, double w, Brush b, DoubleCollection? dash, double frac, double secondsPerTurn) {
        var e = new Ellipse { Width = r * 2, Height = r * 2, Stroke = b, StrokeThickness = w, StrokeDashArray = dash, Margin = new Thickness(R - r), RenderTransformOrigin = new Point(0.5, 0.5), StrokeDashCap = PenLineCap.Round };
        if (frac < 1) { var circ = 2 * Math.PI * r / w; e.StrokeDashArray = new DoubleCollection { circ * frac, circ * (1 - frac) }; }
        var rot = new RotateTransform(); e.RenderTransform = rot;
        rot.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, secondsPerTurn > 0 ? 360 : -360, TimeSpan.FromSeconds(Math.Abs(secondsPerTurn))) { RepeatBehavior = RepeatBehavior.Forever });
        ringCanvas.Children.Add(e);
    }
    public new void Show() { base.Show(); Activate(); input.Focus(); Keyboard.Focus(input); }
    public void HideHud() { if (pendingConfirm != null) Resolve(false); Hide(); }
    public void SetStatus(string s) { status.Text = s; }
    public void ClearOutput() { output.Clear(); }
    public void AppendLine(string s) { output.AppendText(s + "\n\n"); output.ScrollToEnd(); }
    public void AppendStep(string s) { output.AppendText(s + "\n"); output.ScrollToEnd(); }
    public void ShowAndAsk(string q) { Show(); Ask(q); }
    void Input_KeyDown(object sender, KeyEventArgs e) {
        if (e.Key != Key.Return) return; e.Handled = true;
        if (pendingConfirm != null) { Resolve(true); return; }
        var q = input.Text.Trim(); if (q.Length == 0 || Busy) return; input.Clear(); AI.Spoken = false; Ask(q);
    }
    public async void Ask(string q, bool quiet = false) {
        if (Busy) { AppendLine("(one moment, sir — still working)"); return; }
        Busy = true; if (!quiet) AppendLine("> " + q); SetStatus("THINKING  (Esc to stop)"); input.IsEnabled = false;
        try { var r = await AI.Ask(q); AppendLine(r); }
        catch (Exception ex) { AppendLine("Error: " + ex.Message); }
        finally { Busy = false; AI.Spoken = false; SetStatus(Voice.Shared.Running ? "LISTENING" : "READY"); input.IsEnabled = true; if (IsVisible) { input.Focus(); Keyboard.Focus(input); } }
    }
    public Task<bool> Confirm(string what) {
        Show(); pendingConfirm = new TaskCompletionSource<bool>();
        AppendLine("⚠ Confirm — " + what + "\n[Enter] proceed   [Esc] cancel"); SetStatus("AWAITING CONFIRMATION"); input.IsEnabled = true; input.Focus(); Keyboard.Focus(input);
        return pendingConfirm.Task;
    }
    void Resolve(bool ok) { var p = pendingConfirm; pendingConfirm = null; AppendStep(ok ? "✓ confirmed" : "✗ cancelled"); input.IsEnabled = false; p?.TrySetResult(ok); }
}

/// Small always-on-top telemetry readout (Ctrl+Alt+Space).
sealed class OverlayWindow : Window {
    readonly TextBlock tb = new();
    readonly System.Windows.Threading.DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(3) };
    public OverlayWindow() {
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize; ShowActivated = false; SizeToContent = SizeToContent.WidthAndHeight;
        var wa = SystemParameters.WorkArea; Left = wa.Left + 10; Top = wa.Bottom - 230;
        tb.FontFamily = new FontFamily("Consolas"); tb.FontSize = 12; tb.Foreground = App.CyanBrush; tb.TextWrapping = TextWrapping.Wrap; tb.MaxWidth = 520;
        Content = new Border { CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Color.FromArgb(190, 0, 24, 44)), BorderBrush = App.DimBrush, BorderThickness = new Thickness(1), Padding = new Thickness(12, 8, 12, 8), Child = tb };
        MouseLeftButtonDown += (_, _) => DragMove(); MouseRightButtonDown += (_, _) => Close();
        timer.Tick += async (_, _) => tb.Text = await Task.Run(() => Stats.Summary(true)); timer.Start(); tb.Text = "collecting telemetry…";
        Closed += (_, _) => timer.Stop();
    }
}

static class Ui {
    public static Window Dialog(string title, double w) => new Window { Title = title, Width = w, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterScreen, ResizeMode = ResizeMode.NoResize, Topmost = true, ShowInTaskbar = false };
    public static Button PasteButton(TextBox target) { var b = new Button { Content = "Paste", Width = 52, Margin = new Thickness(6, 0, 0, 0) }; b.Click += (_, _) => { try { if (Clipboard.ContainsText()) target.Text = Clipboard.GetText().Trim(); } catch { } }; return b; }
    public static Grid Form(params (string label, UIElement field)[] rows) {
        var g = new Grid { Margin = new Thickness(14) }; g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); g.ColumnDefinitions.Add(new ColumnDefinition());
        int i = 0;
        foreach (var (label, field) in rows) {
            g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var l = new TextBlock { Text = label, Margin = new Thickness(0, 6, 10, 6), VerticalAlignment = VerticalAlignment.Center }; Grid.SetRow(l, i); g.Children.Add(l);
            if (field is FrameworkElement fe) fe.Margin = new Thickness(0, 4, 0, 4); Grid.SetRow(field, i); Grid.SetColumn(field, 1); g.Children.Add(field); i++;
        }
        return g;
    }
    public static StackPanel Buttons(Window w, Action onSave) {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(14, 0, 14, 14) };
        var save = new Button { Content = "Save", Width = 80, IsDefault = true, Margin = new Thickness(0, 0, 8, 0) }; save.Click += (_, _) => { onSave(); w.Close(); };
        var cancel = new Button { Content = "Cancel", Width = 80, IsCancel = true };
        sp.Children.Add(save); sp.Children.Add(cancel); return sp;
    }
}

sealed class ProviderDialog {
    readonly Window w = Ui.Dialog("AI Provider", 480);
    public ProviderDialog() {
        var combo = new ComboBox(); foreach (var p in AI.Presets) combo.Items.Add(p.Name);
        var idx = Array.FindIndex(AI.Presets, p => p.Name == AI.ProviderName); combo.SelectedIndex = idx < 0 ? 0 : idx;
        var b = new TextBox { Text = AI.Base }; var m = new TextBox { Text = AI.Model }; var k = new TextBox { Text = AI.ApiKey };
        var kp = new DockPanel(); var pb = Ui.PasteButton(k); DockPanel.SetDock(pb, Dock.Right); kp.Children.Add(pb); kp.Children.Add(k);
        var hint = new TextBlock { FontSize = 11, Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap };
        void Hint() { var p = AI.Presets[combo.SelectedIndex]; hint.Text = p.KeyURL.Length > 0 ? "Get a key: " + p.KeyURL : ""; }
        combo.SelectionChanged += (_, _) => { var p = AI.Presets[combo.SelectedIndex]; b.Text = p.Base; m.Text = p.Model; Hint(); }; Hint();
        var sp = new StackPanel(); sp.Children.Add(Ui.Form(("Provider", combo), ("Base URL", b), ("Model", m), ("API key", kp), ("", hint)));
        sp.Children.Add(Ui.Buttons(w, () => { var p = AI.Presets[combo.SelectedIndex]; AI.Save(p.Name, p.Kind, b.Text.Trim(), m.Text.Trim(), k.Text.Trim()); AI.ClearHistory(); }));
        w.Content = sp;
    }
    public void ShowDialog() => w.ShowDialog();
}
sealed class SearchDialog {
    readonly Window w = Ui.Dialog("Web Search", 440);
    public SearchDialog() {
        var combo = new ComboBox(); foreach (var p in Search.Presets) combo.Items.Add(p.Name); combo.SelectedIndex = Math.Max(0, Array.FindIndex(Search.Presets, p => p.Name == Search.Provider));
        var k = new TextBox { Text = Search.ApiKey }; var kp = new DockPanel(); var pb = Ui.PasteButton(k); DockPanel.SetDock(pb, Dock.Right); kp.Children.Add(pb); kp.Children.Add(k);
        var hint = new TextBlock { FontSize = 11, Foreground = Brushes.Gray };
        void Hint() { var p = Search.Presets[combo.SelectedIndex]; hint.Text = p.KeyURL.Length > 0 ? "Get a key: " + p.KeyURL : "JARVIS answers from his own knowledge only."; k.IsEnabled = p.KeyURL.Length > 0; }
        combo.SelectionChanged += (_, _) => Hint(); Hint();
        var sp = new StackPanel(); sp.Children.Add(Ui.Form(("Provider", combo), ("API key", kp), ("", hint)));
        sp.Children.Add(Ui.Buttons(w, () => { Settings.Set("searchProvider", Search.Presets[combo.SelectedIndex].Name); Settings.Set("searchKey", k.Text.Trim()); }));
        w.Content = sp;
    }
    public void ShowDialog() => w.ShowDialog();
}
sealed class KeyDialog {
    readonly Window w;
    public KeyDialog(string title, string help, string current, Action<string> save) {
        w = Ui.Dialog(title, 440);
        var k = new TextBox { Text = current }; var kp = new DockPanel(); var pb = Ui.PasteButton(k); DockPanel.SetDock(pb, Dock.Right); kp.Children.Add(pb); kp.Children.Add(k);
        var sp = new StackPanel(); sp.Children.Add(Ui.Form(("Key", kp), ("", new TextBlock { Text = help, FontSize = 11, Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap })));
        sp.Children.Add(Ui.Buttons(w, () => save(k.Text.Trim()))); w.Content = sp;
    }
    public void ShowDialog() => w.ShowDialog();
}
