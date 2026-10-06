# Pompom - assistant Windows (lance par le jeu, invisible).
# Ecrit une ligne JSON toutes les ~1,5 s sur stdout :
#   idle  : secondes depuis la derniere entree clavier/souris
#   proc  : nom du processus au premier plan, title : titre de la fenetre, path : chemin de l'exe
#   fs    : fenetre au premier plan en plein ecran
#   self  : la fenetre au premier plan est Pompom
# Il retire aussi la fenetre du compagnon de la barre des taches et la garde au premier plan.
param([int]$ParentPid = 0, [long]$Hwnd = 0)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PW {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
  [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] static extern int DwmGetCloaked(IntPtr h, int attr, out int v, int size);

  public static void DpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { } }

  // Fenetres visibles, de l'avant vers l'arriere : [[hwnd, x, y, w, h, maximisee], ...]
  public static string Windows(uint selfPid) {
    var sb = new StringBuilder("[");
    int n = 0;
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h) || IsIconic(h)) return true;
      int cl; if (DwmGetCloaked(h, 14, out cl, 4) == 0 && cl != 0) return true;
      long ex = GetWindowLongPtr(h, -20).ToInt64();
      if ((ex & 0x80L) != 0) return true;
      if (Pid(h) == selfPid) return true;
      string c = ClassOf(h);
      if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return true;
      if (GetWindowTextLength(h) == 0) return true;
      RECT r;
      if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
      if (r.R - r.L < 140 || r.B - r.T < 80) return true;
      if (n > 0) sb.Append(',');
      sb.Append('[').Append(h.ToInt64()).Append(',').Append(r.L).Append(',').Append(r.T).Append(',')
        .Append(r.R - r.L).Append(',').Append(r.B - r.T).Append(',').Append(IsZoomed(h) ? 1 : 0).Append(']');
      n++;
      return n < 30;
    }, IntPtr.Zero);
    sb.Append(']');
    return sb.ToString();
  }

  public static double IdleSeconds() {
    var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
    if (!GetLastInputInfo(ref l)) return 0;
    return unchecked((uint)Environment.TickCount - l.dwTime) / 1000.0;
  }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static bool IsFullscreen(IntPtr h) {
    if (h == IntPtr.Zero) return false;
    string c = ClassOf(h);
    if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
    RECT r; if (!GetWindowRect(h, out r)) return false;
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
  public static void MakeToolWindow(IntPtr h) {
    long ex = GetWindowLongPtr(h, -20).ToInt64();
    ex = (ex | 0x80L | 0x08000000L) & ~0x40000L; // TOOLWINDOW | NOACTIVATE, sans APPWINDOW
    ShowWindow(h, 0);
    SetWindowLongPtr(h, -20, new IntPtr(ex));
    ShowWindow(h, 4);
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
  // Barre des taches principale : [x, y, w, h] (en masquage automatique, elle sort presque entierement de l'ecran)
  public static string Taskbar() {
    IntPtr t = FindWindow("Shell_TrayWnd", null);
    RECT r;
    if (t == IntPtr.Zero || !GetWindowRect(t, out r)) return "[]";
    return "[" + r.L + "," + r.T + "," + (r.R - r.L) + "," + (r.B - r.T) + "]";
  }
  public static void KeepTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
}
"@

[PW]::DpiAware()
if ($Hwnd -ne 0) { [PW]::MakeToolWindow([IntPtr]$Hwnd) }
$pathCache = @{}
$tick = 0
$meetRun = $false
$recRun = $false
$meetNames = @('Zoom', 'Teams', 'ms-teams', 'webex', 'CiscoCollabHost', 'GoToMeeting', 'Skype')
$recNames = @('obs64', 'obs32', 'obs', 'XSplit.Core', 'Streamlabs OBS', 'Streamlabs Desktop', 'Twitch Studio')
while ($true) {
  try {
    if ($ParentPid -ne 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
    $fg = [PW]::GetForegroundWindow()
    $fpid = [int][PW]::Pid($fg)
    $name = ''
    $path = ''
    if ($fpid -ne 0) {
      if ($pathCache.ContainsKey($fpid)) {
        $name = $pathCache[$fpid][0]; $path = $pathCache[$fpid][1]
      } else {
        $p = Get-Process -Id $fpid -ErrorAction SilentlyContinue
        if ($p) { $name = $p.ProcessName; $path = [string]$p.Path }
        $pathCache[$fpid] = @($name, $path)
      }
    }
    $o = [ordered]@{
      idle  = [math]::Round([PW]::IdleSeconds(), 1)
      proc  = $name
      title = [PW]::Title($fg)
      path  = $path
      fs    = [PW]::IsFullscreen($fg)
      self  = ($fpid -eq $ParentPid)
      fg    = $fg.ToInt64()
      meet  = $meetRun
      rec   = $recRun
    }
    $json = ($o | ConvertTo-Json -Compress)
    $json = $json.Substring(0, $json.Length - 1) + ',"wins":' + [PW]::Windows([uint32]$ParentPid) + ',"tb":' + [PW]::Taskbar() + '}'
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
    if ($Hwnd -ne 0) { [PW]::KeepTop([IntPtr]$Hwnd) }
    $tick++
    if ($tick % 8 -eq 1) {
      $meetRun = [bool](Get-Process -Name $meetNames -ErrorAction SilentlyContinue)
      $recRun = [bool](Get-Process -Name $recNames -ErrorAction SilentlyContinue)
    }
    if ($tick % 2400 -eq 0) { $pathCache.Clear() }
  } catch { }
  Start-Sleep -Milliseconds 250
}
