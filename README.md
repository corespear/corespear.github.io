# Remote Copilot CLI Agent Setup instructions

A dependency-free, **loopback-only** HTTP wrapper around the installed `copilot` CLI. It uses `System.Net.HttpListener` and never creates a shell command from request input.
Make sure to create session.json first

## Launch Server

```powershell
powershell -ExecutionPolicy Bypass -File .\RemoteCliAgent.ps1
```

Server runs on `http://127.0.0.1:8787`

## Expose to devtunnel

```powershell
devtunnel host -p 8787 --allow-anonymous
```


