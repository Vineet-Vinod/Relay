# Relay macOS Agent

The agent runs on the Mac you want to control from the Relay iPhone app. It keeps one outbound secure WebSocket connected to `Server/`, and launches interactive shell sessions on demand.

## Pair

Generate a pairing code in the Relay iPhone app first, then run:

```bash
cd /Users/matthew/Projects/Catapult26/Relay/Agent
go run . pair \
  --server "https://192.168.1.10:8443" \
  --code "PAIRCODE" \
  --allow-insecure-tls
```

This writes `~/.relay-agent/config.json`.

## Run

```bash
cd Agent
go run .
```

The agent reconnects automatically if the server drops.
