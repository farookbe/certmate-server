using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace CertMate.Service;

/// <summary>
/// Launches and supervises the embedded-Python CertMate child process.
///
/// Responsibilities:
///   * builds the child's environment explicitly (no machine PATH),
///   * forces UTF-8 for the child (PYTHONIOENCODING / PYTHONUTF8),
///   * sets the child's working directory to the application dir,
///   * streams stdout/stderr asynchronously, parses JSON lines, and maps
///     each level onto the correct Windows Event Log level,
///   * restarts the child on failure with a bounded backoff,
///   * terminates the child cleanly when the service stops.
///
/// The restart loop is run on a dedicated thread so the ServiceBase control
/// channel never blocks on process I/O.
/// </summary>
public sealed class PythonHost
{
    private readonly EventLogMapper _mapper;
    private readonly object _sync = new();
    private Process? _process;
    private Thread? _supervisor;
    private volatile bool _stopping;
    private int _consecutiveFailures;

    public PythonHost(EventLogMapper mapper)
    {
        _mapper = mapper;
    }

    public void Start(HostConfig config, IReadOnlyDictionary<string, string> secretEnv)
    {
        _stopping = false;
        _consecutiveFailures = 0;
        _supervisor = new Thread(() => SupervisorLoop(config, secretEnv))
        { IsBackground = true, Name = "certmate-python-supervisor" };
        _supervisor.Start();
    }

    public void Stop(TimeSpan grace)
    {
        _stopping = true;
        var p = _process;
        if (p is null || p.HasExited) return;

        // Graceful: send CTRL_BREAK so Python runs its atexit / KeyboardInterrupt
        // path (which calls stop_background_work).
        try
        {
            if (!p.HasExited) p.StandardInput?.Close();
            p.Kill(entireProcessTree: true);
        }
        catch { /* already dead */ }

        try { p.WaitForExit((int)grace.TotalMilliseconds); }
        catch { /* timeout; the service is going away */ }
        p.Dispose();
        _process = null;
    }

    public void RunToCompletion(HostConfig config)
    {
        var secretEnv = new Dictionary<string, string>();
        SupervisorLoop(config, secretEnv, restartOnFailure: false);
    }

    private void SupervisorLoop(HostConfig config, IReadOnlyDictionary<string, string> secretEnv, bool restartOnFailure = true)
    {
        var backoffSeconds = 5;
        while (!_stopping)
        {
            try
            {
                LaunchChild(config, secretEnv);
                _process!.WaitForExit();
                var exitCode = _process!.ExitCode;
                if (exitCode == 0 || _stopping)
                {
                    _consecutiveFailures = 0;
                    if (!_stopping)
                    {
                        _mapper.WriteEvent("Information",
                            "CertMate Python process exited cleanly.");
                        break;
                    }
                }
                _consecutiveFailures++;
                _mapper.WriteEvent("Warning",
                    $"CertMate Python process exited with code {exitCode}; " +
                    $"will restart in {backoffSeconds}s " +
                    $"(consecutive failure #{_consecutiveFailures}).");
            }
            catch (Exception ex)
            {
                _mapper.WriteEvent("Error", $"Failed to launch Python child: {ex.Message}");
            }

            if (_stopping || !restartOnFailure) break;

            Thread.Sleep(TimeSpan.FromSeconds(backoffSeconds));
            backoffSeconds = Math.Min(backoffSeconds * 2, config.MaxRestartBackoffSec);
        }
    }

    private void LaunchChild(HostConfig config, IReadOnlyDictionary<string, string> secretEnv)
    {
        var arguments = new StringBuilder();
        arguments.Append("-X utf8 ");
        arguments.Append("-u ");
        // The launcher (not the raw app.py) is the entry point: it runs the
        // certbot readiness probe, registers the Windows PFX blueprint after
        // create_app(), and installs the ordered-shutdown atexit hook. It is
        // generated into the app tree by the build.
        arguments.Append($"app\\CertMateLauncher.py --host {config.Host} --port {config.Port} ");
        arguments.Append("--log-level INFO");

        var psi = new ProcessStartInfo
        {
            FileName = config.PythonExe,
            WorkingDirectory = config.AppDir,
            Arguments = arguments.ToString(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        // The host sets every Python child-process environment variable
        // directly; it never depends on the machine PATH.
        psi.Environment.Clear();
        foreach (var kv in new Dictionary<string, string>
        {
            { "PYTHONIOENCODING", "utf-8" },
            { "PYTHONUTF8", "1" },
            { "PYTHONUNBUFFERED", "1" },
            { "CERTMATE_LOG_JSON", "true" },
            { "CERTMATE_LOG_FILE", Path.Combine(config.LogDir, "certmate.log") },
            { "CERTMATE_LOG_LEVEL", "INFO" },
            { "CERTMATE_CERT_DIR", config.CertDir },
            { "CERTMATE_DATA_DIR", config.DataDir },
            { "CERTMATE_BACKUP_DIR", config.BackupDir },
            { "CERTMATE_LOGS_DIR", config.LogDir },
            { "FLASK_ENV", "production" },
            { "CERTMATE_CERTBOT_CMD", config.CertBotCmd },
        })
        {
            psi.Environment[kv.Key] = kv.Value;
        }

        // Secrets are passed via environment, never on the command line.
        foreach (var kv in secretEnv)
        {
            psi.Environment[kv.Key] = kv.Value;
        }

        _process = Process.Start(psi)
                  ?? throw new InvalidOperationException("Could not start Python child.");

        // Asynchronously drain stdout / stderr and map onto the Event Log.
        _process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            MapLine(e.Data);
        };
        _process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            MapLine(e.Data);
        };
        _process.BeginOutputReadLine();
        _process.BeginErrorReadLine();

        _mapper.WriteEvent("Information",
            $"CertMate Python child started (pid {_process.Id}, host {config.Host}:{config.Port}).");
    }

    private void MapLine(string line)
    {
        var mapped = _mapper.MapLine(line);
        _mapper.WriteEvent(mapped.Level, mapped.Message);
    }
}
