# Relay WireGuard Server

Minimal centralized WireGuard control server for macOS, with startup and smoke-test notes for the Relay iOS app.

## What It Does

- Uses a logical WireGuard interface name of `wg0` and resolves the real macOS `utunX` interface created by `wireguard-go`.
- Applies outbound NAT with `pfctl`.
- Tracks peers in memory and auto-assigns `10.0.0.x` addresses.
- Exposes an HTTP API for registration, inspection, and client config templates.
- Monitors peer handshakes and reconciles WireGuard peer state continuously.

## Relay App Status

The Relay app now has a Relay VPN path in-app:

- saved devices remain the SSH target source
- devices can be added by hostname or IP address
- Relay VPN onboarding is driven from the app settings
- the intended flow is a single user-facing Relay app download

The app still keeps a Tailscale path:

- Tailscale remains an alternate network path rather than a separate device provider
- users can add Tailscale hostnames or IP addresses manually and SSH over an already-working Tailscale connection

Current integration note:

- the repo now includes the packet-tunnel target and WireGuardKit wiring, but on this host Xcode 26.4 currently fails inside upstream `WireGuardKitC` while compiling the official package
- the server startup and smoke-test flow below is still the intended all-in-one app flow once the iOS build is green on your machine

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

For the Relay iOS app smoke test, use the helper script:

```bash
cd Server
cp .env.example .env
# edit .env with a LAN-reachable HTTP address and the correct server endpoint
chmod +x scripts/start-relay-for-ios.sh
./scripts/start-relay-for-ios.sh
```

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

## Control API

The Relay app uses the same `POST /register` control API.

Manual registration is still useful for debugging:

```bash
wg genkey | tee client.key | wg pubkey > client.pub

curl -X POST http://127.0.0.1:8080/register \
  -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"alice\",\"public_key\":\"$(cat client.pub)\"}"
```

Inspect peers:

```bash
curl http://127.0.0.1:8080/peers
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

For the all-in-one Relay app smoke test on the same LAN, set:

```dotenv
RELAY_HTTP_ADDR=0.0.0.0:8080
RELAY_SERVER_ENDPOINT=YOUR_MAC_LAN_IP:51820
RELAY_EGRESS_INTERFACE=en0
```

For remote testing, set:

```dotenv
RELAY_HTTP_ADDR=0.0.0.0:8080
RELAY_SERVER_ENDPOINT=YOUR_PUBLIC_IP_OR_DNS:51820
RELAY_EGRESS_INTERFACE=en0
```

Then start the server:

```bash
./scripts/start-relay-for-ios.sh
```

Important:

- `/register` has no authentication in this MVP
- only bind `RELAY_HTTP_ADDR=0.0.0.0:8080` on a trusted LAN for smoke tests
- for public internet deployment you should put this control API behind authentication and HTTPS first

### 3. Register And Connect In Relay

In the Relay app on iPhone or iPad:

1. Open `Settings`.
2. In `Network`, choose `Relay VPN`.
3. Enter the Relay control server URL:
   `http://YOUR_MAC_LAN_IP:8080`
4. Keep or edit the generated peer identifier.
5. Tap `Register And Connect`.
6. Accept the iOS VPN permission prompt.

Relay should:

- generate the client WireGuard keypair on-device
- call `POST /register`
- install the packet-tunnel profile
- connect the VPN tunnel

On the server you should then see the new peer in:

```bash
curl http://127.0.0.1:8080/peers
sudo wg show
```

### 4. Add The Device In Relay

In the Relay app:

1. Open the `Devices` tab.
2. Tap `+`.
3. Add the target device using its reachable VPN IP or hostname.

For the simplest test, if the server Mac is also the SSH target, enter:

- Host: `10.0.0.1`
- User: your macOS username
- Port: `22`
- Label: anything you want

Important:

- enter the VPN IP of the SSH target, not the public `RELAY_SERVER_ENDPOINT`
- the device shows as online only if Relay can open a quick TCP probe to the configured SSH port

### 5. Connect In Relay

In Relay:

1. Refresh the `Devices` tab if needed.
2. Tap the saved device.
3. On first connection, verify and trust the SSH host fingerprint if it matches the target machine.
4. Enter the SSH password.

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

Relay still supports a Tailscale path, but it stays intentionally simple:

1. make sure the device is already connected to Tailscale outside Relay
2. add the peer using its Tailscale hostname or Tailscale IP
3. SSH as usual

So the intended distinction now is:

- Relay VPN: Relay owns the tunnel and SSH
- Tailscale: Tailscale owns the tunnel, Relay owns SSH

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
