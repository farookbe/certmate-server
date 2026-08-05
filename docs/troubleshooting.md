# Troubleshooting

## Service status

```powershell
Get-Service CertMate
Get-CimInstance Win32_Service -Filter "Name='CertMate'" | Select Name,State,StartName,ProcessId,PathName
```

## Logs

```powershell
Get-Content C:\CertMate\logs\*.log -Tail 200
```

## Manual app test

```powershell
Stop-Service CertMate
cd C:\CertMate
.\venv\Scripts\python.exe -u .\app.py
```

## DNS alias public lookup

```powershell
C:\CertMate\venv\Scripts\python.exe -c "import requests,json; r=requests.get('https://cloudflare-dns.com/dns-query',params={'name':'_acme-challenge.example.com','type':'CNAME'},headers={'accept':'application/dns-json'}); print(json.dumps(r.json(),indent=2))"
```
