# Relay WireGuard Server

Minimal centralized WireGuard control server for macOS.

## What It Does

- Uses a logical WireGuard interface name of `wg0` and resolves the real macOS `utunX` interface created by `wireguard-go`.
- Applies outbound NAT with `pfctl`.
- Tracks peers in memory and auto-assigns `10.0.0.x` addresses.
- Exposes an HTTP API for registration, inspection, and client config templates.
- Monitors peer handshakes and reconciles WireGuard peer state continuously.

## Requirements

- macOS host
- root privileges
- `wg`
- `wireguard-go`
- `pfctl`

## Install WireGuard Tools

Using Homebrew:

```bash
brew install wireguard-tools wireguard-go
```

Verify:

```bash
which wg
which wireguard-go
```

## Run The Server

From the repo root:

```bash
cd Server
go build -o relay-server .
sudo ./relay-server
```

Optional environment variables:

```bash
export RELAY_HTTP_ADDR=":8080"
export RELAY_WG_INTERFACE="wg0"
export RELAY_WG_ADDRESS="10.0.0.1/24"
export RELAY_WG_LISTEN_PORT="51820"
export RELAY_PERSISTENT_KEEPALIVE="25"
export RELAY_SERVER_ENDPOINT="YOUR_PUBLIC_IP_OR_DNS:51820"
export RELAY_EGRESS_INTERFACE="en0"
export RELAY_STATE_DIR="./.state"
```

If `RELAY_SERVER_ENDPOINT` is not set, the server uses the detected IPv4 address of the active default-route interface.

The server does not use `wg-quick` on macOS. It starts `wireguard-go utun`, resolves the real interface name from `WG_TUN_NAME_FILE`, applies configuration with `wg`, and assigns `10.0.0.1/24` with `ifconfig`.

## Register A Peer

Generate a client keypair on the client:

```bash
wg genkey | tee client.key | wg pubkey > client.pub
```

Register the peer:

```bash
curl -X POST http://127.0.0.1:8080/register \
  -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"alice\",\"public_key\":\"$(cat client.pub)\"}"
```

Example response:

```json
{
  "assigned_ip": "10.0.0.2",
  "server_public_key": "SERVER_PUBLIC_KEY",
  "server_endpoint": "SERVER_IP:51820",
  "persistent_keepalive": 25
}
```

Inspect peers:

```bash
curl http://127.0.0.1:8080/peers
```

Fetch a client config template:

```bash
curl http://127.0.0.1:8080/config/alice
```

## Example Client Config

The server intentionally stores only the client's public key, not the private key. Replace the placeholder with the private key generated on the client.

```ini
[Interface]
PrivateKey = REPLACE_WITH_CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

## Verify Traffic Routing

On the server:

```bash
sudo wg show
sudo pfctl -a com.apple/relay -s nat
sysctl net.inet.ip.forwarding
```

On the client:

```bash
curl https://ifconfig.me
ping 10.0.0.1
```

For iPhone testing, import `client.conf` into the official WireGuard app and activate the tunnel there.

For macOS client testing without `wg-quick`:

```bash
mkdir -p /var/run/wireguard
export WG_TUN_NAME_FILE=/var/run/wireguard/client.name
sudo wireguard-go utun
CLIENT_IF=$(sudo cat /var/run/wireguard/client.name)
sudo wg setconf "$CLIENT_IF" client.conf
sudo ifconfig "$CLIENT_IF" inet 10.0.0.2/24 10.0.0.2 alias
sudo ifconfig "$CLIENT_IF" up
```

You should see:

- the client handshake in `wg show`
- `net.inet.ip.forwarding: 1`
- the PF NAT rule for `10.0.0.0/24`
- client traffic egressing through the macOS server
