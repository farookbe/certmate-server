using System;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace CertMate.Service;

/// <summary>
/// Generates the persistent, strong secrets that the Inno Setup postinstall
/// step writes to the DPAPI-protected bundle.
///
/// Three secrets, generated once and never rotated automatically (they are
/// the identity of this instance; rotating one invalidates the matching
/// clients, so rotation is a deliberate operator action):
///
///   * api_bearer_token     - 64 hex chars, used by the operator's own API
///                             key and by the dashboard Bearer header.
///   * session_secret        - Flask SECRET_KEY, signs session cookies.
///   * encrypted_backup_pass - passphrase wrapping the unified backups.
///
/// Every secret is drawn from RNG.NextBytes so the value is at least as
/// strong as a 256-bit symmetric key and never derived from predictable
/// material.
/// </summary>
public static class SecretBootstrap
{
    public static string GenerateApiBearerToken()
    {
        var buf = new byte[32];
        RandomNumberGenerator.Fill(buf);
        return Convert.ToHexString(buf).ToLowerInvariant();
    }

    public static string GenerateSessionSecret()
    {
        var buf = new byte[64];
        RandomNumberGenerator.Fill(buf);
        return Convert.ToHexString(buf).ToLowerInvariant();
    }

    public static string GenerateBackupPassphrase()
    {
        // 32 chars, base64url, 256 bits of entropy.
        var buf = new byte[32];
        RandomNumberGenerator.Fill(buf);
        return ToBase64Url(buf);
    }

    public static IReadOnlyDictionary<string, string> GenerateDefaultSecrets()
    {
        return new Dictionary<string, string>
        {
            { "api_bearer_token", GenerateApiBearerToken() },
            { "session_secret", GenerateSessionSecret() },
            { "encrypted_backup_pass", GenerateBackupPassphrase() },
        };
    }

    private static string ToBase64Url(byte[] input)
    {
        return Convert.ToBase64String(input)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
