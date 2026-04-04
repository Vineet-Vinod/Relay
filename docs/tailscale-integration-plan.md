# Tailscale Integration Plan

Relay will treat mesh networking as an optional provider, not as a hard-coded part of the terminal app. The immediate goal is to use Tailscale for private network reachability and device discovery while keeping the app architecture ready for a future Relay-owned VPN or another provider.

## Approach

The app should depend on a `MeshProvider` interface that is responsible for:

- reporting mesh status
- fetching available peer devices
- resolving the reachable endpoint for a selected device

The terminal and SSH layers should remain separate from this provider. Relay asks the mesh layer for a host to connect to, then uses its own SSH client to open the terminal session.

## Tailscale As The First Real Provider

The first production provider will be `TailscaleMeshProvider`.

Its responsibilities:

- detect whether Tailscale is available and active
- fetch device and network metadata from Tailscale
- return a stable mesh address or hostname for each peer
- surface setup or availability issues in a user-friendly way

This keeps Tailscale handling what it is already good at:

- secure private connectivity
- device identity
- peer discovery
- stable mesh addressing

Relay stays focused on:

- app UI
- peer selection
- terminal experience
- SSH execution

## Seamless User Experience

The intended user experience is:

1. Relay checks the selected mesh provider.
2. If Tailscale is ready, Relay loads peers and shows which devices are reachable.
3. When the user selects a device, Relay resolves the mesh endpoint and opens SSH.
4. If Tailscale is not installed, not authenticated, or not connected, Relay shows clear guidance instead of failing deep in the SSH flow.

This allows Tailscale to feel built in from the user’s perspective without Relay owning the VPN tunnel itself.

## Keeping The Door Open

The key architectural rule is that the UI should never depend directly on Tailscale-specific types or assumptions.

That means:

- peer list screens should consume generic `PeerDevice` models
- connection flows should use generic mesh status and endpoint results
- SSH should only know about a resolved host and port

With this boundary in place, Relay can add other providers later, such as:

- a custom `RelayVPNMeshProvider`
- a WireGuard-backed provider
- another enterprise mesh or zero-trust network source

Those future providers should satisfy the same app-facing contract, so replacing or supplementing Tailscale does not require rewriting the terminal UX.

## Near-Term Implementation Steps

1. Rename the current mesh discovery layer to a more explicit provider abstraction.
2. Keep `MockMeshProvider` for local development and previews.
3. Add `TailscaleMeshProvider` as the first real implementation.
4. Inject the active provider through app configuration.
5. Keep SSH transport independent from mesh provider choice.
6. Add provider-specific setup and error states in the UI where needed.

## Outcome

This plan gives Relay a pragmatic first integration with Tailscale while preserving a clean migration path to another mesh backend later. Tailscale can be the first and only real option initially, but it should not become a permanent architectural constraint.
