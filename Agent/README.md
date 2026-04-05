# Relay macOS Agent

The agent runs on the Mac you want to control from the Relay iPhone app. It keeps one outbound secure WebSocket connected to `Server/`, and launches interactive shell sessions on demand.

## Pair

Generate a pairing code in the Relay iPhone app first, then run:

```bash
cd /Users/matthew/Projects/Catapult26/Relay/Agent
./scripts/pair-agent.sh 192.168.1.10:8443 PAIRCODE --allow-insecure-tls
```

This writes `~/.relay-agent/config.json`.

The pairing script accepts either:

- a full server URL like `https://relay.example.com:8443`
- or a host and port like `192.168.1.10:8443`, which it will normalize to `https://...`

Extra flags are passed through to `go run . pair`, so you can also do:

```bash
./scripts/pair-agent.sh 192.168.1.10:8443 PAIRCODE --name "Home Mac"
```

## Run

```bash
cd /Users/matthew/Projects/Catapult26/Relay/Agent
./scripts/run-agent.sh
```

The agent reconnects automatically if the server drops.
