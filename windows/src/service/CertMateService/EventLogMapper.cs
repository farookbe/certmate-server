using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.Json;

namespace CertMate.Service;

public sealed record MappedLine(string Level, string Message);

// The mapper itself only depends on `System.Diagnostics.EventLog` and
// `System.Text.Json`; keeping this file free of ServiceBase means the
// same class is unit-testable from a plain console host if we ever
// need to validate the JSON classification without the service shell.

/// <summary>
/// Parses a single CertMate stdout/stderr line and decides which Windows
/// Event Log level it should be written at.
///
/// CertMate's structured logger emits one JSON object per line. The JSON
/// carries a `level` field with one of: debug, info, warning, error,
/// critical. Lines that are not JSON (e.g. the certbot subprocess stderr,
/// a traceback header, an uncaught Python banner) are classified by the
/// Event Log Information level, so they are visible without being
/// mistaken for errors.
///
/// The mapping table is:
///   debug     -> Information (visible in Event Viewer, low priority)
///   info      -> Information
///   warning   -> Warning
///   error     -> Error
///   critical  -> Critical
///   (non-JSON) -> Information
///
/// The requirement that "info messages do not appear as Windows Event Log
/// errors" is enforced by keeping Information out of the Error bucket and
/// only escalating to Error/Critical when the JSON says so.
/// </summary>
public sealed class EventLogMapper
{
    private static readonly Dictionary<string, string> LEVEL_TO_EVENTLOG = new()
    {
        ["debug"]     = "Information",
        ["info"]      = "Information",
        ["notice"]    = "Information",
        ["warning"]   = "Warning",
        ["warn"]      = "Warning",
        ["error"]     = "Error",
        ["err"]       = "Error",
        ["critical"]  = "Critical",
        ["fatal"]     = "Critical",
    };

    private readonly EventLog _log;
    private readonly int _maxMessageLength;

    public EventLogMapper()
    {
        _log = new EventLog { Source = "CertMate", Log = "Application" };
        _maxMessageLength = 60000;
    }

    public MappedLine MapLine(string line)
    {
        line = line ?? string.Empty;
        if (line.Length == 0)
            return new MappedLine("Information", string.Empty);

        // Cheap pre-check: JSON object lines start with `{`.
        if (line[0] == '{')
        {
            try
            {
                using var doc = JsonDocument.Parse(line);
                if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("level", out var levelEl) &&
                    levelEl.ValueKind == JsonValueKind.String)
                {
                    var level = levelEl.GetString()?.ToLowerInvariant() ?? "info";
                    var mapped = LEVEL_TO_EVENTLOG.TryGetValue(level, out var target)
                        ? target : "Information";
                    // Prefer the JSON `message` field when present; fall back
                    // to the raw line so operators never lose data.
                    string message;
                    if (doc.RootElement.TryGetProperty("message", out var msgEl) &&
                        msgEl.ValueKind == JsonValueKind.String)
                    {
                        message = msgEl.GetString()!;
                    }
                    else
                    {
                        message = line;
                    }
                    return new MappedLine(mapped, Truncate(message));
                }
            }
            catch (JsonException)
            {
                // Malformed JSON: fall through and log the raw line as
                // Information so nothing is silently dropped.
            }
        }

        return new MappedLine("Information", Truncate(line));
    }

    public void WriteEvent(string level, string message)
    {
        if (string.IsNullOrWhiteSpace(message)) return;
        try
        {
            switch (level)
            {
                case "Warning":
                    _log.WriteEntry(message, EventLogEntryType.Warning);
                    break;
                case "Error":
                    _log.WriteEntry(message, EventLogEntryType.Error);
                    break;
                case "Critical":
                    _log.WriteEntry(message, EventLogEntryType.Error);
                    break;
                default:
                    _log.WriteEntry(message, EventLogEntryType.Information);
                    break;
            }
        }
        catch (Exception ex)
        {
            // Never let Event Log failures block the service loop. The
            // message is still available in the local file log kept by
            // the Inno Setup postinstall step and by CertMate's own
            // structured file logging.
            Console.Error.WriteLine($"[CertMateService] Event Log write failed: {ex.Message}");
        }
    }

    private string Truncate(string s)
    {
        if (string.IsNullOrEmpty(s) || s.Length <= _maxMessageLength) return s;
        return s.Substring(0, _maxMessageLength) + "... [truncated]";
    }
}
