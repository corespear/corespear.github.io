# Remote Copilot CLI Agent

A dependency-free, **loopback-only** HTTP wrapper around the installed `copilot` CLI. It uses `System.Net.HttpListener` and never creates a shell command from request input.
Make sure to create session.json first

## Launch

```powershell
powershell -ExecutionPolicy Bypass -File .\RemoteCliAgent.ps1
```

The default listener is `http://127.0.0.1:8787/`. Change its port or use IPv6 loopback only:

```powershell
.\RemoteCliAgent.ps1 -Port 9000
.\RemoteCliAgent.ps1 -BindAddress ::1 -Port 8787
```

Press `Ctrl+C` to stop the server cleanly. The `copilot` executable must be on `PATH`; otherwise valid requests return a JSON error.

Open the browser client directly from the local path: `file:///C:/Users/Claw/Desktop/RemoteCliAgent/chat.html`. No separate static-file server is needed. The API sends permissive CORS headers so the file-based client can call the loopback server.

## API

`GET /sessions` returns the saved session records. Other API endpoints require `POST`, `Content-Type: application/json`, and a UTF-8 JSON object. `OPTIONS` requests are accepted for CORS preflight. Errors are JSON objects with an `error.code` and `error.message` field.

### Create a session

`POST /new-session` accepts an optional `prompt`. Without one, the service sends a short initialization prompt. The response includes a generated GUID `sessionId` and the Copilot CLI output in `response`. Each created session is persisted in the runtime-only `session.json` file with its UTC `createdAt` timestamp.

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/new-session `
  -ContentType 'application/json' `
  -Body (@{ prompt = 'Reply with exactly: ready' } | ConvertTo-Json)
```

```bash
curl -X POST http://127.0.0.1:8787/new-session \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Reply with exactly: ready"}'
```

### Resume a saved session

`POST /resume-session` requires a `sessionId` recorded in `session.json`. It resumes that Copilot session with the prompt `Summarize this session in ~50 words`.

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/resume-session `
  -ContentType 'application/json' `
  -Body (@{ sessionId = '<session-id>' } | ConvertTo-Json)
```

### Continue a session

`POST /chat` requires a GUID `sessionId` and a non-empty `prompt`.

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8787/chat `
  -ContentType 'application/json' `
  -Body (@{ sessionId = '<session-id>'; prompt = 'Say hello.' } | ConvertTo-Json)
```

```bash
curl -X POST http://127.0.0.1:8787/chat \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"<session-id>","prompt":"Say hello."}'
```

The process invokes Copilot with argument-safe PowerShell execution equivalent to:

```text
copilot --session-id <id> --prompt <prompt> --yolo --allow-all-tools --silent
```

It returns a JSON error if Copilot is unavailable or exits unsuccessfully. The listener intentionally accepts only `127.0.0.1` or `::1`, never a public network address.
