# Relay WireGuard Server

Minimal centralized WireGuard control server for macOS, with notes for using it from the Relay iOS app.

## What It Does

- Uses a logical WireGuard interface name of `wg0` and resolves the real macOS `utunX` interface created by `wireguard-go`.
- Applies outbound NAT with `pfctl`.
- Tracks peers in memory and auto-assigns `10.0.0.x` addresses.
- Exposes an HTTP API for registration, inspection, and client config templates.
- Monitors peer handshakes and reconciles WireGuard peer state continuously.

## Relay App Status

The current Relay app no longer depends on hardcoded mock peers.

What the app does today:

- uses a local "Saved Devices" provider
- lets the user add devices manually by IP address, username, and port
- stores saved devices on the iPhone or iPad
- uses Relay's built-in SSH client for the terminal session

What the app does not do yet:

- it does not currently own a WireGuard tunnel
- it does not currently include a first-class Tailscale provider or Tailscale device discovery
- it does not currently accept DNS hostnames in the add-device flow, only IP addresses

That means:

- to use this custom WireGuard server, bring the VPN tunnel up separately in the WireGuard iOS app, then use Relay to SSH to the device's VPN IP
- if a user already has Tailscale, Relay can still SSH over Tailscale, but only by manually adding the peer's Tailscale IP as a saved device

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
cp .env.example .env
# edit .env for your machine
go build -o relay-server .
sudo ./relay-server
```

The server automatically loads `Server/.env` if it exists. Explicit shell environment variables still win over values in `.env`.

Safe template to commit:

```bash
cp .env.example .env
```

You can also point at a different env file:

```bash
sudo RELAY_ENV_FILE=/path/to/relay.env ./relay-server
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

## Use With The Relay iOS App

The cleanest smoke test is to make the server Mac itself reachable over the VPN and SSH to it from Relay.

### 1. Enable SSH On The Target Mac

If you want to SSH to the same Mac that is running the Relay server:

```bash
sudo systemsetup -setremotelogin on
sudo systemsetup -getremotelogin
```

You can also target a different computer, but it must:

- run an SSH server
- be reachable from the iPhone through the VPN
- have a stable VPN IP or another reachable IP address that Relay can store manually

### 2. Start The Relay VPN Server

From the repo root:

```bash
cd Server
cp .env.example .env
```

Edit `.env`.

For LAN testing, set:

```dotenv
RELAY_HTTP_ADDR=127.0.0.1:8080
RELAY_SERVER_ENDPOINT=YOUR_MAC_LAN_IP:51820
RELAY_EGRESS_INTERFACE=en0
```

For remote testing, set:

```dotenv
RELAY_HTTP_ADDR=127.0.0.1:8080
RELAY_SERVER_ENDPOINT=YOUR_PUBLIC_IP_OR_DNS:51820
RELAY_EGRESS_INTERFACE=en0
```

Then build and start:

```bash
go build -o relay-server .
sudo ./relay-server
```

Keep the control API bound to `127.0.0.1` for now. `/register` has no authentication in this MVP.

### 3. Create An iPhone WireGuard Peer

In another terminal on the server Mac:

```bash
mkdir -p /tmp/relay-iphone
cd /tmp/relay-iphone

wg genkey | tee iphone.key | wg pubkey > iphone.pub

curl -X POST http://127.0.0.1:8080/register \
  -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"iphone\",\"public_key\":\"$(tr -d '\n' < iphone.pub)\"}"
```

Take the returned values and create `iphone.conf`:

```ini
[Interface]
PrivateKey = IPHONE_PRIVATE_KEY
Address = ASSIGNED_IP/24

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

You can also use `GET /config/iphone` as a template, but you still need to insert the iPhone private key manually.

Import `iphone.conf` into the official WireGuard iOS app and activate the tunnel there.

If you want Relay to SSH to a different computer on the VPN instead of the server Mac, that computer must also be enrolled as a WireGuard peer and reachable at its own VPN IP.

### 4. Add The Device In Relay

In the Relay app:

1. Open the `Devices` tab.
2. Tap `+`.
3. Add the target device using its reachable IP address.

For the simplest test, if the server Mac is also the SSH target, enter:

- IP Address: `10.0.0.1`
- User: your macOS username
- Port: `22`
- Label: anything you want

Important:

- enter the VPN IP of the SSH target, not the public `RELAY_SERVER_ENDPOINT`
- the current app add-device flow only accepts IP addresses, not hostnames
- the device shows as online only if Relay can open a quick TCP probe to the configured SSH port

### 5. Connect In Relay

In Relay:

1. Ensure the WireGuard tunnel is active in the WireGuard iOS app.
2. Return to Relay and refresh the `Devices` tab.
3. Tap the saved device.
4. On first connection, verify and trust the SSH host fingerprint if it matches the target machine.
5. Enter the SSH password.

After a successful password login, Relay may offer to generate and store an SSH key locally for future logins. That key stays on the device.

### 6. Verify The End-To-End Path

On the server:

```bash
sudo wg show
curl http://127.0.0.1:8080/peers
sudo pfctl -a com.apple/relay -s nat
sysctl net.inet.ip.forwarding
```

In Relay:

- the device should show `Online`
- the SSH fingerprint prompt should appear on first connect
- the terminal should open after login

## Using Relay With Tailscale

There is no first-class Tailscale provider in the current app build yet.

If the device already has Tailscale connectivity outside Relay, the current app can still be used by:

1. making sure the device is already connected to Tailscale
2. manually adding the peer's Tailscale IP address as a saved device in Relay
3. connecting over SSH as usual

So today the distinction is:

- custom Relay server: WireGuard app owns the tunnel, Relay owns SSH
- Tailscale: Tailscale app owns the tunnel, Relay owns SSH

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
