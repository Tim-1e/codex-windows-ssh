using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Codex_Fix")]
[assembly: AssemblyProduct("Codex_Fix")]
[assembly: AssemblyDescription("Stable launcher for Codex Windows SSH")]

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "Start-Codex.vbs");
        bool validate = arguments.Length == 1 &&
            string.Equals(arguments[0], "--validate", StringComparison.OrdinalIgnoreCase);

        try
        {
            if (!File.Exists(script))
            {
                throw new FileNotFoundException("The Codex VBS launcher is missing.", script);
            }

            string scriptHost = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                validate ? "cscript.exe" : "wscript.exe"
            );
            var startInfo = new ProcessStartInfo
            {
                FileName = scriptHost,
                Arguments = "//nologo \"" + script + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (validate)
            {
                startInfo.EnvironmentVariables["CODEX_WINDOWS_SSH_LAUNCHER_VALIDATE"] = "resolve";
            }

            Process process = Process.Start(startInfo);
            if (validate)
            {
                process.WaitForExit();
                return process.ExitCode;
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(
                error.Message,
                "Codex_Fix launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 1;
        }
    }
}
