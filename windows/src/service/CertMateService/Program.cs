// CertMate .NET Windows Service Host.
//
// This service launches the embedded Python CertMate application as a child
// process and:
//   * captures stdout and stderr asynchronously,
//   * parses CertMate's structured JSON output,
//   * maps debug/info/warning/error/critical onto the correct Windows
//     Event Log level (so an `info` line does not appear as an error),
//   * restarts the Python child on failure with a bounded retry and
//     exponential backoff,
//   * enforces a single instance through a global named mutex,
//   * terminates the child cleanly when the service stops.
//
// All file paths and environment variables for the child are resolved by the
// host itself; the host never depends on machine-global PATH.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;

namespace CertMate.Service;

public static class Program
{
    public static void Main(string[] args)
    {
        IHostBuilder builder = Microsoft.Extensions.Hosting.Host.CreateDefaultBuilder(args);
        builder.ConfigureServices((_, services) =>
        {
            services.AddSingleton<EventLogMapper>();
            services.AddSingleton<HostConfig>(sp => HostConfig.From(sp));
            services.AddSingleton<PythonHost>();
            services.AddSingleton<SecretsProvider>();
            services.AddSingleton<CertMateWindowsService>();
        });

        // `init-secrets` subcommand: the Inno Setup postinstall step invokes
        // the host with this flag to generate the DPAPI bundle on the first
        // install, so the operator does not need to type 96 hex chars.
        if (args.Any(a => a.Equals("init-secrets", StringComparison.OrdinalIgnoreCase)))
        {
            var host = builder.Build();
            using (host)
            {
                var secrets = SecretBootstrap.GenerateDefaultSecrets();
                var provider = host.Services.GetRequiredService<SecretsProvider>();
                provider.Save(secrets);
                Console.WriteLine(
                    "CertMate secrets bundle written and DPAPI-protected.\n" +
                    "  api_bearer_token      = " + secrets["api_bearer_token"].Substring(0, 8) +
                    "... (first 8 chars; the full token is in the bundle)\n" +
                    "  session_secret        = " + secrets["session_secret"].Substring(0, 8) +
                    "...\n" +
                    "  encrypted_backup_pass = " + secrets["encrypted_backup_pass"].Substring(0, 8) +
                    "...\n" +
                    "Recover the full values from the bundle if you need to use them with\n" +
                    "external clients; never log them to an operator-visible surface.");
            }
            return;
        }

        if (args.Any(a => a.Equals("--run-foreground", StringComparison.OrdinalIgnoreCase)))
        {
            // Foreground mode (debugging): run the Python host as a plain
            // process without the ServiceBase wrapper.
            var host = builder.Build();
            using (host)
            {
                var config = host.Services.GetRequiredService<HostConfig>();
                var python = host.Services.GetRequiredService<PythonHost>();
                python.RunToCompletion(config);
            }
            return;
        }

        // `export-pfx <domain>` subcommand: the .NET host's authoritative PFX
        // export entry point. A dashboard "Export PFX" button calls this
        // (via the local API), or an operator runs it from the console. It
        // shells out to the embedded Python's export_pfx.py tool so the same
        // cryptography code path (password + full chain + key) is used in
        // every context.
        if (args.Any(a => a.Equals("export-pfx", StringComparison.OrdinalIgnoreCase)))
        {
            Environment.Exit(RunExportPfx(args));
        }

        // `check-update` / `update <tag>` subcommands: the .NET host's
        // authoritative upstream-update entry point. `check-update` is
        // check-only (safe, no install). `update` runs the full staged
        // pipeline; without `--admin-approval` it stops after staging +
        // backup, exactly mirroring the documented safety model.
        if (args.Any(a => a.Equals("check-update", StringComparison.OrdinalIgnoreCase)))
        {
            Environment.Exit(RunCheckUpdate(args, install: false));
        }
        if (args.Any(a => a.Equals("update", StringComparison.OrdinalIgnoreCase)))
        {
            Environment.Exit(RunCheckUpdate(args, install: true));
        }

        var app = builder.Build();
        app.Run();
    }

    private static string? GetAssemblyDir()
    {
        // `AppContext.BaseDirectory` is the reliable path in a single-file
        // publish; `Assembly.Location` is empty in that mode (IL3000).
        return AppContext.BaseDirectory;
    }

    // ---------------------------------------------------------------------
    // Subcommand helpers
    // ---------------------------------------------------------------------

    private static int RunExportPfx(string[] args)
    {
        int idx = Array.FindIndex(args, a => a.Equals("export-pfx", StringComparison.OrdinalIgnoreCase));
        var domain = idx + 1 < args.Length ? args[idx + 1] : null;
        if (string.IsNullOrEmpty(domain))
        {
            Console.Error.WriteLine("usage: CertMateService.exe export-pfx <domain> [--out <path>] " +
                "[--password-file <f> | --password-env <name> | --password <pw>]");
            return 2;
        }

        var config = new HostConfig();
        var certDir = config.CertDir;
        var outPath = GetOptionValue(args, "--out") ?? Path.Combine(
            Directory.GetCurrentDirectory(), domain + ".pfx");
        var py = config.PythonExe;
        var toolsDir = Path.Combine(GetAssemblyDir(), "tools");

        var pfxTool = Path.Combine(toolsDir, "export_pfx.py");
        if (!File.Exists(pfxTool))
        {
            Console.Error.WriteLine($"PFX tool not found at {pfxTool}");
            return 4;
        }

        var psi = new ProcessStartInfo
        {
            FileName = py,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Directory.GetCurrentDirectory(),
        };
        psi.ArgumentList.Add(pfxTool);
        psi.ArgumentList.Add(domain);
        psi.ArgumentList.Add("--cert-dir");
        psi.ArgumentList.Add(certDir);
        psi.ArgumentList.Add("--out");
        psi.ArgumentList.Add(outPath);
        var pwFile = GetOptionValue(args, "--password-file");
        if (pwFile is not null) { psi.ArgumentList.Add("--password-file"); psi.ArgumentList.Add(pwFile); }
        var pwEnv = GetOptionValue(args, "--password-env");
        if (pwEnv is not null) { psi.ArgumentList.Add("--password-env"); psi.ArgumentList.Add(pwEnv); }
        var pw = GetOptionValue(args, "--password");
        if (pw is not null) { psi.ArgumentList.Add("--password"); psi.ArgumentList.Add(pw); }

        using var proc = Process.Start(psi);
        string stdout = proc!.StandardOutput.ReadToEnd();
        string stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        Console.Write(stdout);
        if (!string.IsNullOrEmpty(stderr)) Console.Error.Write(stderr);
        return proc.ExitCode;
    }

    private static int RunCheckUpdate(string[] args, bool install)
    {
        var config = new HostConfig();
        var py = config.PythonExe;
        var pf = "C:\\Program Files\\CertMate";
        var toolsDir = Path.Combine(GetAssemblyDir(), "tools");
        var updaterTool = Path.Combine(toolsDir, "updater.py");
        if (!File.Exists(updaterTool))
        {
            Console.Error.WriteLine($"Updater tool not found at {updaterTool}");
            return 4;
        }

        var psi = new ProcessStartInfo
        {
            FileName = py,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Directory.GetCurrentDirectory(),
        };
        psi.ArgumentList.Add(updaterTool);
        psi.ArgumentList.Add("--program-files");
        psi.ArgumentList.Add(pf);
        if (install)
        {
            psi.ArgumentList.Add("--admin-approval");
            var target = GetOptionValue(args, "--target");
            if (target is not null) { psi.ArgumentList.Add("--target"); psi.ArgumentList.Add(target); }
            if (args.Any(a => a.Equals("--no-backup", StringComparison.OrdinalIgnoreCase)))
                psi.ArgumentList.Add("--no-backup");
            var jsonOut = GetOptionValue(args, "--json-out");
            if (jsonOut is not null) { psi.ArgumentList.Add("--json-out"); psi.ArgumentList.Add(jsonOut); }
        }
        else
        {
            psi.ArgumentList.Add("--check-only");
        }

        using var proc = Process.Start(psi);
        string stdout = proc!.StandardOutput.ReadToEnd();
        string stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        Console.Write(stdout);
        if (!string.IsNullOrEmpty(stderr)) Console.Error.Write(stderr);
        return proc.ExitCode;
    }

    private static string? GetOptionValue(string[] args, string option)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals(option, StringComparison.OrdinalIgnoreCase))
                return args[i + 1];
        }
        return null;
    }
}
