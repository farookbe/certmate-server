# Security Notes

This repository intentionally excludes secrets.

Do not commit:

- `.env`
- `data/settings.json`
- Azure client secrets
- certificates
- private keys
- logs containing tokens

Recommended production improvement:

- Move Azure DNS client secret to Azure Key Vault.
- Use Managed Identity where possible.
- Put CertMate behind IIS/Caddy/Nginx HTTPS reverse proxy.
- Restrict access to CertMate management interface.
