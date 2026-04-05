# Relay HTTPS Server

Relay now uses an HTTPS and WebSocket relay instead of WireGuard. The Swift app can keep its direct SSH/Tailscale path, and switch to `Relay` when you want remote shell access through a centralized server and a paired macOS agent.

## What This Server Does

- Issues app registrations to Relay on iPhone.
- Generates short-lived pairing codes.
- Accepts macOS agent pairing requests.
- Keeps one persistent WebSocket per paired agent.
- Brokers per-session WebSockets between the iPhone app and the Mac agent.

## Environment

The server requires HTTPS. For local development, use a self-signed or `mkcert` certificate and enable `Allow Self-Signed TLS` in the Relay app and `--allow-insecure-tls` in the Mac agent.

The server auto-loads `Server/.env` on startup. Environment variables already set in the shell still win over `.env`.

Required variables:

- `RELAY_PUBLIC_URL`
- `RELAY_TLS_CERT_FILE`
- `RELAY_TLS_KEY_FILE`

Optional variables:

- `RELAY_HTTP_ADDR` default `:8443`
- `RELAY_DATA_FILE` default `./data/relay-store.json`
- `RELAY_PAIRING_TTL` default `10m`
- `RELAY_SESSION_TTL` default `2m`

## Quick Start

1. Generate a local certificate.

Using `mkcert`:

```bash
brew install mkcert
mkcert -install
mkdir -p Server/certs
mkcert -cert-file Server/certs/relay-cert.pem -key-file Server/certs/relay-key.pem 127.0.0.1 localhost 192.168.1.10
```

Replace `192.168.1.10` with the LAN IP of the Mac running the server.

2. Start the server.

```bash
cd /Users/matthew/Projects/Catapult26/Relay/Server
chmod +x scripts/start-relay-dev.sh
cp .env.example .env
```

Edit `Server/.env`:

```dotenv
RELAY_PUBLIC_URL=https://192.168.1.10:8443
RELAY_TLS_CERT_FILE=./certs/relay-cert.pem
RELAY_TLS_KEY_FILE=./certs/relay-key.pem
```

Then run:

```bash
./scripts/start-relay-dev.sh
```

If you want a different file path, set `RELAY_ENV_FILE` before starting the server.

3. Pair the iPhone app.

In Relay on iPhone:

- Open `Settings`
- In `Connection`, choose `Relay`
- Set the server URL to `https://192.168.1.10:8443`
- Enable `Allow Self-Signed TLS` if you used `mkcert` or another self-signed cert
- Tap `Register This iPhone`
- Tap `Create Pairing Code`

4. Pair the Mac agent.

Build and run the agent from the repo root:

```bash
cd /Users/matthew/Projects/Catapult26/Relay/Agent
./scripts/pair-agent.sh 192.168.1.10:8443 PAIRCODE --allow-insecure-tls
./scripts/run-agent.sh
```

5. Connect from the app.

- Go back to `Devices`
- Leave the provider set to `Relay`
- Wait for the paired Mac to show online
- Tap it to open a terminal session

## Smoke Test Flow

This is the full all-in-one app path. The WireGuard app is no longer involved.

1. Start `Server/` with TLS.
2. Register the iPhone inside Relay.
3. Generate a pairing code inside Relay.
4. Pair and start `Agent/` on the Mac you want to control.
5. In Relay, switch to the `Devices` tab and open the paired Mac.

If the path is healthy:

- `GET /healthz` returns `{"status":"ok"}`
- the Mac shows up under the Relay provider
- tapping the Mac opens a shell without needing the WireGuard app

## Development Notes

- The server stores app and agent registrations in `Server/data/relay-store.json`.
- App and agent bearer tokens are hashed before they are persisted.
- Pairing codes are in-memory and expire automatically.
- Sessions are ephemeral and expire if the app never attaches.
