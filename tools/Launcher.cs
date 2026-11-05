// PathShrink.exe: opens PathShrink.ps1 from the same folder in Windows PowerShell 5.1,
// without a console window. Built by tools\Build-Release.ps1 with the C# compiler of
// .NET Framework 4 (C# 5), which every Windows 10 and 11 has. Runs as the current user
// (asInvoker); the window offers to open again as administrator when it needs to.
// Arguments are passed on to PathShrink.ps1 (-Path, -Pro, -Language...).
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "PathShrink.ps1");
        string module = Path.Combine(dir, "PathShrink\\PathShrink.psd1");
        if (!File.Exists(ps1) || !File.Exists(module))
        {
            MessageBox.Show(MissingText(), "PathShrink", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 2;
        }
        string shell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe");
        StringBuilder line = new StringBuilder("-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
        line.Append(Quote(ps1));
        foreach (string a in args) { line.Append(' ').Append(Quote(a)); }
        ProcessStartInfo psi = new ProcessStartInfo(shell, line.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        // Started from PowerShell 7, the inherited PSModulePath points Windows PowerShell at
        // modules it cannot load; without it, powershell.exe builds its own default.
        psi.EnvironmentVariables.Remove("PSModulePath");
        try { Process.Start(psi); }
        catch (Exception e)
        {
            MessageBox.Show(e.Message, "PathShrink", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    static string MissingText()
    {
        string lang = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        if (lang == "es") { return "Extrae el zip entero en una carpeta y abre PathShrink.exe desde ahi.\nLa carpeta PathShrink y PathShrink.ps1 tienen que estar junto al exe."; }
        if (lang == "pt") { return "Extraia o zip inteiro para uma pasta e abra o PathShrink.exe a partir dai.\nA pasta PathShrink e o PathShrink.ps1 tem de estar junto do exe."; }
        return "Extract the whole zip to a folder and open PathShrink.exe from there.\nThe PathShrink folder and PathShrink.ps1 must be next to the exe.";
    }

    // One argument for CommandLineToArgvW: backslashes before a quote are doubled.
    static string Quote(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) { return a; }
        StringBuilder sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
            sb.Append('\\', slashes).Append(c); slashes = 0;
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }
}
