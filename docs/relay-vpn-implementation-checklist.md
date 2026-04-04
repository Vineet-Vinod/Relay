# Relay VPN Implementation Checklist

This checklist is the concrete implementation plan for making Relay a single-download iOS app that can:

- manage its own WireGuard tunnel against `Server/`
- keep the existing manual SSH device flow
- preserve a Tailscale path without forcing Tailscale-specific coupling into the rest of the app

## Architecture

- Keep device management separate from network-path management.
- Continue using saved devices for SSH targets.
- Add Relay VPN as a new settings-managed subsystem instead of replacing the existing provider layer.
- Keep Tailscale support as a parallel path:
  - Relay should allow hostnames as well as IP addresses
  - Relay should not require a Tailscale-specific code path just to SSH over an already-working Tailscale network

## Implementation Steps

### 1. App-side Relay VPN Domain And State

- Add a `RelayNetworkPath` preference with:
  - `Relay VPN`
  - `Tailscale`
  - `Direct`
- Add a Relay VPN controller responsible for:
  - loading installed tunnel state
  - tracking `NETunnelProviderManager` status
  - registering the device with the Go server
  - installing and removing the tunnel profile
  - connecting and disconnecting the tunnel
- Persist non-sensitive profile metadata locally for UI display.
- Store the actual tunnel configuration securely behind a persistent keychain reference.

### 2. App-side Relay VPN Onboarding

- Add settings UI for:
  - selecting the preferred network path
  - entering the Relay control server URL
  - entering or regenerating the peer identifier used with `/register`
  - registering and connecting the Relay VPN
  - disconnecting and removing the Relay VPN profile
- Use the Go server `POST /register` endpoint to provision the device.
- Generate the client WireGuard keypair on-device.

### 3. Packet Tunnel Integration

- Add an iOS packet-tunnel extension target.
- Add app and extension entitlements for `packet-tunnel-provider`.
- Decode the stored Relay tunnel configuration inside the extension.
- Start and stop the WireGuard tunnel through `WireGuardKit`.

### 4. Preserve Tailscale Without Deep Coupling

- Keep manual saved devices as the SSH target source.
- Allow hostnames in the add-device sheet so MagicDNS and custom DNS names work.
- Treat Tailscale as an alternate network path, not a different host-management model.

### 5. Server Alignment

- Update `Server/README.md` to document LAN-accessible control API startup for iOS onboarding.
- Add a helper script for starting the server in a Swift-app smoke-test configuration.
- Document the all-in-one smoke test without relying on the WireGuard iOS app.

## Current Scope

This branch is implementing the Relay app-side onboarding, settings, hostname support, and packet-tunnel scaffolding now.

One Xcode-specific integration remains inherently coupled to WireGuardKit:

- `WireGuardGoBridgeiOS` external build target setup, which WireGuard’s own integration guide requires because SwiftPM cannot build the bridge automatically.

That target can still be represented in-project, but it is the one area most likely to need a final Xcode validation pass after the code changes land.
