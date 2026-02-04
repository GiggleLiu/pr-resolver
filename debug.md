# Debug Log: Webhook Not Processing [action] Command

## Date: 2026-02-04

## Symptom
User commented `[action]` on PR https://github.com/GiggleLiu/yao-rs/pull/17 but no job was queued.

## Investigation

### 1. Initial Issue: Tunnel URL Not Working
The original named tunnel (`06bb40ff-....cfargotunnel.com`) was returning 502 errors because:
- Named tunnels require DNS configuration in Cloudflare dashboard
- The `config.yml` had incorrect hostname routing

**Fix:** Switched to Quick Tunnel (`trycloudflare.com`) which works immediately:
```bash
cloudflared tunnel --url http://localhost:8787
```
New URL: `https://wings-easy-luke-todd.trycloudflare.com`

### 2. Webhooks Updated
All repo webhooks were updated to use the new URL:
```bash
gh api repos/OWNER/REPO/hooks/HOOK_ID --method PATCH --input - <<EOF
{"config":{"url":"https://wings-easy-luke-todd.trycloudflare.com/webhook",...}}
EOF
```

### 3. Webhook Received But 500 Error
After fixing the tunnel, the webhook was received but returned HTTP 500:
```
2026-02-04 14:54:29,056 [INFO] Received [action] from GiggleLiu/yao-rs#17
INFO: 140.82.115.16:0 - "POST /webhook HTTP/1.1" 500 Internal Server Error
```

### 4. Root Cause: `gh` Not in PATH
The server crashed when trying to call `gh` to get the PR branch:
```
File "/Users/jinguomini/server/pr-resolver/.claude/webhook/server.py", line 325, in get_pr_branch
    result = subprocess.run(
FileNotFoundError: [Errno 2] No such file or directory: 'gh'
```

**Why:** The launchd service runs with a minimal PATH that doesn't include `/opt/homebrew/bin` where `gh` is installed.

### 5. Fix Required
Update the launchd plist to include the correct PATH:
```xml
<key>EnvironmentVariables</key>
<dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
</dict>
```

Or update `server.py` to use full paths for commands.

## Lessons Learned

1. **Named tunnels vs Quick tunnels:**
   - Named tunnels (`cloudflared tunnel create NAME`) need DNS config
   - Quick tunnels (`cloudflared tunnel --url`) work immediately but URL changes on restart

2. **PATH in launchd services:**
   - launchd services don't inherit shell PATH
   - Must explicitly set PATH in plist or use absolute paths in code

3. **Error visibility:**
   - 500 errors from FastAPI need stderr logs to debug
   - Add more logging around subprocess calls

## Status
- [x] Fix PATH in launchd plist or server.py → Added `SUBPROCESS_ENV` with correct PATH
- [x] Restart server with correct PATH → Cleared `__pycache__` and restarted with `-B` flag
- [x] Re-test webhook → Working! Job queued and processed

## Resolution
Added `SUBPROCESS_ENV` dict in server.py that includes `/opt/homebrew/bin` in PATH:
```python
SUBPROCESS_ENV = {
    **os.environ,
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", ""),
}
```
All `subprocess.run()` calls now use `env=SUBPROCESS_ENV`.

## Next: Set Up Named Tunnel
Quick tunnels (`trycloudflare.com`) change URL on restart. For permanent URLs, need to configure DNS for the named tunnel.
