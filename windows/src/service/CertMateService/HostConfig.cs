using System;
using System.IO;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace CertMate.Service;

/// <summary>
/// Resolves the non-secret configuration that the host reads from the
/// on-disk appsettings.json next to the executable plus Windows environment
/// overrides. Secrets never live here; see <see cref="SecretsProvider"/>.
/// </summary>
public sealed class HostConfig
{
    public string PythonExe { get; set; } =
        @"C:\Program Files\CertMate\python\python.exe";

    public string AppDir { get; set; } = @"C:\Program Files\CertMate\app";

    public string CertBotCmd { get; set; } =
        @"C:\Program Files\CertMate\certbot.bat";

    public string Host { get; set; } = "127.0.0.1";

    public int Port { get; set; } = 8000;

    public string DataDir { get; set; } = @"C:\ProgramData\CertMate\data";
    public string CertDir { get; set; } = @"C:\ProgramData\CertMate\certificates";
    public string BackupDir { get; set; } = @"C:\ProgramData\CertMate\backups";
    public string LogDir { get; set; } = @"C:\ProgramData\CertMate\logs";

    public int MaxRestartBackoffSec { get; set; } = 120;
    public int RestartGraceSec { get; set; } = 10;
    public int HealthCheckTimeoutSec { get; set; } = 30;

    public static HostConfig From(IServiceProvider services)
    {
        var config = services.GetRequiredService<IConfiguration>();

        var hostConfig = new HostConfig();
        config.Bind(hostConfig);

        // Environment overrides always win.
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("CERTMATE_HOST")))
            hostConfig.Host = Environment.GetEnvironmentVariable("CERTMATE_HOST")!;
        if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("CERTMATE_PORT")))
            hostConfig.Port = int.Parse(Environment.GetEnvironmentVariable("CERTMATE_PORT")!);

        return hostConfig;
    }
}
