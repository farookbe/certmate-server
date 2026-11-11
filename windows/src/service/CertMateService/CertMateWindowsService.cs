using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Threading;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace CertMate.Service;

/// <summary>
/// ServiceBase that launches the embedded-Python child, enforces a single
/// instance, and restarts the child with bounded backoff on failure.
/// </summary>
public sealed class CertMateWindowsService : ServiceBase
{
    private readonly PythonHost _python;
    private readonly HostConfig _config;
    private readonly SecretsProvider _secrets;
    private readonly Mutex _instanceLock;
    private readonly EventLog _eventLog;
    private bool _stopRequested;

    public CertMateWindowsService(PythonHost python, HostConfig config, SecretsProvider secrets)
    {
        _python = python;
        _config = config;
        _secrets = secrets;
        _instanceLock = new Mutex(true, @"Global\CertMate.App.Lock", out var isFirst);
        if (!isFirst)
        {
            // Another CertMate application instance already holds the lock.
            // Refuse to start; the second instance is the misconfiguration.
            throw new InvalidOperationException(
                "Another CertMate application instance is already running. " +
                "Only one instance is permitted.");
        }
        _eventLog = new EventLog { Source = "CertMate", Log = "Application" };
    }

    protected override void OnStart(string[] startArgs)
    {
        // Materialise secrets via DPAPI so the child inherits them in
        // environment variables (not on the command line).
        var secretEnv = _secrets.Load();
        EnsureDir(_config.LogDir);
        EnsureDir(_config.DataDir);
        EnsureDir(_config.CertDir);
        EnsureDir(_config.BackupDir);

        _python.Start(_config, secretEnv);
        LogInfo("Service started; Python host launched.");
    }

    protected override void OnStop()
    {
        _stopRequested = true;
        _python.Stop(TimeSpan.FromSeconds(_config.RestartGraceSec));
        LogInfo("Service stopped; Python host terminated cleanly.");
    }

    protected override void OnShutdown()
    {
        OnStop();
    }

    private static void EnsureDir(string path)
    {
        if (!string.IsNullOrEmpty(path) && !Directory.Exists(path))
        {
            Directory.CreateDirectory(path);
        }
    }

    private void LogInfo(string message)
    {
        try { _eventLog.WriteEntry(message, EventLogEntryType.Information); }
        catch { /* never let Event Log block the service loop */ }
    }
}
