# Pompom - petit assistant presse-papiers (lance par ClipboardKeeper seulement si l'option est activee).
# Ne lit JAMAIS le contenu texte/image : il surveille seulement le numero de sequence du presse-papiers
# (GetClipboardSequenceNumber, tres peu couteux) et decrit le nouveau contenu, une ligne JSON par changement :
#   {"ev":"clip","seq":N,"init":bool,"sens":bool,"own":bool,"txt":bool,"img":bool,"files":[...],"nfiles":n}
#     sens  : contenu marque "a ne pas surveiller" par un gestionnaire de mots de passe
#             (ExcludeClipboardContentFromMonitorProcessing, Clipboard Viewer Ignore,
#              CanIncludeInClipboardHistory = 0) -> le jeu l'ignore.
#     own   : contenu place par le jeu lui-meme (ou par ce helper).
#     files : chemins copies dans l'Explorateur (5 max).
# Commandes recues sur stdin (une par ligne) :
#   img <png en base64> [<chemin en base64>] -> met l'image dans le presse-papiers (bitmap + "PNG" [+ fichier])
#   txt <texte utf-8 en base64>  -> met du texte (avec reessais si le presse-papiers est occupe)
#   files <chemins separes par des retours a la ligne, en base64> -> met une liste de fichiers (comme un Ctrl+C dans l'Explorateur)
#   quit
# Reponse : {"ev":"set","ok":bool,"kind":"img"|"txt"|"files","busy":"processus qui bloquait"}
param([int]$ParentPid = 0)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class PompomClip {
  [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string n);
  [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr h);
  [DllImport("user32.dll")] static extern bool CloseClipboard();
  [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint f);
  [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
  [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr h);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint DragQueryFile(IntPtr h, uint i, StringBuilder s, uint n);

  const uint CF_TEXT = 1, CF_BITMAP = 2, CF_DIB = 8, CF_UNICODETEXT = 13, CF_HDROP = 15, CF_DIBV5 = 17;
  static uint fExclude, fIgnore, fHistory, fPng;
  static ConcurrentQueue<string> cmds = new ConcurrentQueue<string>();
  static uint ownSeq = 0xFFFFFFFF;

  static string Esc(string s) {
    var sb = new StringBuilder();
    foreach (char c in s) {
      if (c == '"' || c == '\\') { sb.Append('\\').Append(c); }
      else if (c < 32) { sb.Append("\\u").Append(((int)c).ToString("x4")); }
      else sb.Append(c);
    }
    return sb.ToString();
  }

  static void Emit(string json) { Console.Out.WriteLine(json); Console.Out.Flush(); }

  static bool Open() {
    for (int i = 0; i < 8; i++) { if (OpenClipboard(IntPtr.Zero)) return true; Thread.Sleep(15); }
    return false;
  }

  // Valeur DWORD d'un format (CanIncludeInClipboardHistory...). -1 = absent, -2 = illisible.
  static long ReadDword(uint fmt) {
    if (fmt == 0 || !IsClipboardFormatAvailable(fmt)) return -1;
    if (!Open()) return -2;
    try {
      IntPtr h = GetClipboardData(fmt);
      if (h == IntPtr.Zero) return -2;
      IntPtr p = GlobalLock(h);
      if (p == IntPtr.Zero) return -2;
      try { return (uint)Marshal.ReadInt32(p); } finally { GlobalUnlock(h); }
    } finally { CloseClipboard(); }
  }

  static List<string> Files(out int count) {
    var list = new List<string>();
    count = 0;
    if (!IsClipboardFormatAvailable(CF_HDROP) || !Open()) return list;
    try {
      IntPtr h = GetClipboardData(CF_HDROP);
      if (h == IntPtr.Zero) return list;
      count = (int)DragQueryFile(h, 0xFFFFFFFF, null, 0);
      for (uint i = 0; i < count && i < 5; i++) {
        var sb = new StringBuilder(1024);
        DragQueryFile(h, i, sb, 1024);
        list.Add(sb.ToString());
      }
    } finally { CloseClipboard(); }
    return list;
  }

  static void Describe(uint seq, bool init, int parentPid) {
    bool sens = false;
    if (fExclude != 0 && IsClipboardFormatAvailable(fExclude)) sens = true;
    if (fIgnore != 0 && IsClipboardFormatAvailable(fIgnore)) sens = true;
    long hist = ReadDword(fHistory);
    if (hist == 0 || hist == -2) sens = true;
    uint opid = 0;
    IntPtr owner = GetClipboardOwner();
    if (owner != IntPtr.Zero) GetWindowThreadProcessId(owner, out opid);
    bool own = (seq != 0 && seq == ownSeq) || (opid != 0 && (opid == (uint)parentPid || opid == (uint)Process.GetCurrentProcess().Id));
    bool txt = IsClipboardFormatAvailable(CF_UNICODETEXT) || IsClipboardFormatAvailable(CF_TEXT);
    bool img = IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_DIBV5) || IsClipboardFormatAvailable(CF_BITMAP)
      || (fPng != 0 && IsClipboardFormatAvailable(fPng));
    string pname = "";
    if (opid != 0) { try { pname = Process.GetProcessById((int)opid).ProcessName; } catch { } }
    int n = 0;
    var files = sens ? new List<string>() : Files(out n);
    var sb = new StringBuilder();
    sb.Append("{\"ev\":\"clip\",\"seq\":").Append(seq).Append(",\"init\":").Append(init ? "true" : "false")
      .Append(",\"sens\":").Append(sens ? "true" : "false").Append(",\"own\":").Append(own ? "true" : "false")
      .Append(",\"txt\":").Append(txt ? "true" : "false").Append(",\"img\":").Append(img ? "true" : "false")
      .Append(",\"proc\":\"").Append(Esc(pname)).Append('"')
      .Append(",\"nfiles\":").Append(n).Append(",\"files\":[");
    for (int i = 0; i < files.Count; i++) { if (i > 0) sb.Append(','); sb.Append('"').Append(Esc(files[i])).Append('"'); }
    sb.Append("]}");
    Emit(sb.ToString());
  }

  // "img <png base64> [<chemin base64>]" : avec un chemin, le fichier est aussi propose (coller dans l'Explorateur).
  static void SetImage(string args) {
    bool ok = false;
    try {
      string[] parts = args.Split(' ');
      byte[] png = Convert.FromBase64String(parts[0]);
      using (var ms = new MemoryStream(png))
      using (var bmp = new System.Drawing.Bitmap(ms)) {
        var data = new DataObject();
        data.SetImage(bmp);
        data.SetData("PNG", false, new MemoryStream(png));
        if (parts.Length > 1) {
          string path = Encoding.UTF8.GetString(Convert.FromBase64String(parts[1]));
          if (File.Exists(path)) { var col = new StringCollection(); col.Add(path); data.SetFileDropList(col); }
        }
        Clipboard.SetDataObject(data, true, 20, 50);
        ok = true;
      }
    } catch { }
    ownSeq = GetClipboardSequenceNumber();
    Reply("img", ok);
  }

  // Nom du processus qui garde le presse-papiers ouvert (diagnostic).
  static string Busy() {
    try {
      IntPtr w = GetOpenClipboardWindow();
      if (w == IntPtr.Zero) return "";
      uint pid; GetWindowThreadProcessId(w, out pid);
      return Process.GetProcessById((int)pid).ProcessName;
    } catch { return "?"; }
  }

  static void Reply(string kind, bool ok) {
    Emit("{\"ev\":\"set\",\"kind\":\"" + kind + "\",\"ok\":" + (ok ? "true" : "false") + ",\"busy\":\"" + (ok ? "" : Esc(Busy())) + "\"}");
  }

  static void SetText(string b64) {
    bool ok = false;
    try {
      string t = Encoding.UTF8.GetString(Convert.FromBase64String(b64));
      Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, t), true, 20, 50);
      ok = true;
    } catch { }
    ownSeq = GetClipboardSequenceNumber();
    Reply("txt", ok);
  }

  static void SetFiles(string b64) {
    bool ok = false;
    try {
      string all = Encoding.UTF8.GetString(Convert.FromBase64String(b64));
      var col = new StringCollection();
      foreach (var p in all.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries)) {
        if (File.Exists(p) || Directory.Exists(p)) col.Add(p);
      }
      if (col.Count > 0) {
        var data = new DataObject();
        data.SetFileDropList(col);
        Clipboard.SetDataObject(data, true, 20, 50);
        ok = true;
      }
    } catch { }
    ownSeq = GetClipboardSequenceNumber();
    Reply("files", ok);
  }

  static void Pump() {
    try {
      var r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
      string line;
      while ((line = r.ReadLine()) != null) cmds.Enqueue(line);
    } catch { }
    cmds.Enqueue("quit");
  }

  public static void Run(int parentPid) {
    fExclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    fIgnore = RegisterClipboardFormat("Clipboard Viewer Ignore");
    fHistory = RegisterClipboardFormat("CanIncludeInClipboardHistory");
    fPng = RegisterClipboardFormat("PNG");
    Process parent = null;
    try { if (parentPid != 0) parent = Process.GetProcessById(parentPid); } catch { return; }
    var t = new Thread(Pump);
    t.IsBackground = true;
    t.Start();
    Emit("{\"ev\":\"ready\"}");
    uint last = GetClipboardSequenceNumber();
    Describe(last, true, parentPid);
    int tick = 0;
    while (true) {
      string c;
      while (cmds.TryDequeue(out c)) {
        if (c == "quit") return;
        if (c.StartsWith("img ")) SetImage(c.Substring(4));
        else if (c.StartsWith("txt ")) SetText(c.Substring(4));
        else if (c.StartsWith("files ")) SetFiles(c.Substring(6));
      }
      uint seq = GetClipboardSequenceNumber();
      if (seq != last) {
        last = seq;
        Thread.Sleep(60); // laisse l'application finir d'ecrire tous ses formats
        seq = GetClipboardSequenceNumber();
        last = seq;
        try { Describe(seq, false, parentPid); } catch { }
      }
      if (++tick % 8 == 0 && parent != null) {
        try { parent.Refresh(); if (parent.HasExited) return; } catch { return; }
      }
      Thread.Sleep(250);
    }
  }
}
"@

[PompomClip]::Run($ParentPid)
