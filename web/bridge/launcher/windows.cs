using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using System.Collections.Generic;

// .NET Framework is part of supported Windows installations. Build with its
// compiler; neither a compiler nor Node is needed on the user's computer.
internal sealed class BridgeLauncher : Form {
    private readonly NotifyIcon tray;
    private Process process;
    private StreamWriter log;
    private string address;
    private bool quitting;
    private bool errorShown;

    private BridgeLauncher() {
        Text = "LumenDesk Bridge";
        ShowInTaskbar = false;
        WindowState = FormWindowState.Minimized;
        var menu = new ContextMenuStrip();
        menu.Items.Add("LumenDesk Bridge").Enabled = false;
        menu.Items.Add("Open LumenDesk", null, (sender, args) => Open());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit LumenDesk Bridge", null, (sender, args) => Close());
        tray = new NotifyIcon { Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath), Text = "LumenDesk Bridge", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (sender, args) => Open();
        Shown += (sender, args) => { Hide(); StartBridge(); };
        FormClosing += (sender, args) => Shutdown();
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
    private static ProcessStartInfo Command(bool smoke) {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        return new ProcessStartInfo {
            FileName = Path.Combine(root, "runtime", "node.exe"),
            Arguments = Quote(Path.Combine(root, "launcher", "launch.mjs")) + (smoke ? " --smoke-test" : ""),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = root
        };
    }

    private void Open() {
        if (address != null) Process.Start(new ProcessStartInfo(address) { UseShellExecute = true });
    }
    private void Error(string message) {
        if (quitting || errorShown) return;
        errorShown = true;
        MessageBox.Show(message, "LumenDesk Bridge could not connect", MessageBoxButtons.OK, MessageBoxIcon.Error);
        Close();
    }
    private void StartBridge() {
        try {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".lumendesk");
            Directory.CreateDirectory(directory);
            log = new StreamWriter(Path.Combine(directory, "bridge-launcher.log"), false, Encoding.UTF8) { AutoFlush = true };
            process = new Process { StartInfo = Command(false), EnableRaisingEvents = true };
            process.OutputDataReceived += (sender, args) => {
                if (args.Data == null) return;
                try {
                    var item = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(args.Data);
                    BeginInvoke((Action)(() => {
                        if ((string)item["event"] == "ready") {
                            address = (string)item["url"];
                            Open();
                        } else if ((string)item["event"] == "error") Error((string)item["message"]);
                    }));
                } catch (Exception) { /* Only JSON lifecycle records are UI events. */ }
            };
            process.ErrorDataReceived += (sender, args) => {
                if (args.Data != null) {
                    try { lock (log) { log.WriteLine(args.Data); } }
                    catch (ObjectDisposedException) { /* The bridge has finished closing. */ }
                }
            };
            process.Exited += (sender, args) => {
                if (!quitting && process.ExitCode != 0) BeginInvoke((Action)(() => Error("The local bridge stopped. Reopen LumenDesk Bridge to reconnect. Details are in your .lumendesk/bridge-launcher.log.")));
            };
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        } catch (Exception error) { Error(error.Message); }
    }
    private void Shutdown() {
        quitting = true;
        tray.Visible = false;
        if (process != null) {
            try {
                if (!process.HasExited) {
                    process.StandardInput.WriteLine("quit");
                    process.StandardInput.Flush();
                    if (!process.WaitForExit(3000)) { process.Kill(); process.WaitForExit(1000); }
                    else process.WaitForExit();
                }
            } catch (InvalidOperationException) { /* It has already exited. */ }
            catch (IOException) { /* Closing stdin lets the launcher clean up. */ }
        }
        if (log != null) log.Dispose();
        tray.Dispose();
    }

    [STAThread]
    private static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--smoke-test") {
            var test = new Process { StartInfo = Command(true) };
            test.Start();
            // Drain both pipes asynchronously, including errors, to avoid a
            // deadlock if the startup failure produces more than one buffer.
            var output = test.StandardOutput.ReadToEndAsync();
            var errors = test.StandardError.ReadToEndAsync();
            if (!test.WaitForExit(30000)) { test.Kill(); return 1; }
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "smoke-result.jsonl"), output.Result + errors.Result);
            return test.ExitCode;
        }
        bool first;
        using (var mutex = new Mutex(true, "Local\\LumenDeskBridge-" + Environment.UserName, out first)) {
            if (!first) {
                Process.Start(new ProcessStartInfo("http://127.0.0.1:8765") { UseShellExecute = true });
                return 0;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new BridgeLauncher());
        }
        return 0;
    }
}
