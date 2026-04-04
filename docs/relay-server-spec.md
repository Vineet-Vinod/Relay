# Relay Server Specification

## Status

This document defines the v1 Relay server contract required by the current iOS client in this repository.

It is written for an implementer who has not worked on Relay before and needs to understand:

- why the server exists
- what responsibilities belong on the server
- what responsibilities do not belong on the server
- the HTTP contract the mobile client expects
- the persistence, security, and provider-integration behavior required for the product to work

Unless this document says otherwise, requirements use RFC 2119 language: `MUST`, `SHOULD`, and `MAY`.

## 1. Problem Statement

Relay is a mobile SSH client. The app itself is responsible for:

- user interface
- local credential handling for SSH
- opening SSH sessions directly to remote machines
- terminal rendering

Relay is not intended to own or proxy the SSH transport path to the destination machine.

The missing piece is private-network discovery and account brokerage. A mobile app cannot safely or cleanly embed every third-party provider integration directly. It also needs a product-owned identity layer so external providers can be linked to a Relay account rather than becoming the product's source of truth.

The Relay server exists to solve exactly that.

## 2. Why The Server Exists

The Relay server has four product jobs:

1. Provide Relay-owned authentication.
2. Link external network providers, starting with Tailscale, to a Relay account.
3. Normalize provider data into Relay's app-facing models.
4. Resolve a chosen peer into a concrete SSH endpoint the app can connect to directly.

Without the server:

- the app would need provider-specific OAuth logic and token storage for every provider
- the app would have no Relay-owned user identity
- the app would be tightly coupled to Tailscale's APIs and data model
- changing providers later would require rewriting the app

## 3. Non-Goals

The Relay server is not a general-purpose SSH bastion. In v1 it `MUST NOT`:

- proxy terminal traffic
- terminate or inspect SSH sessions
- store SSH passwords entered by the user in the app
- generate SSH keys for the remote machines on behalf of the app
- act as a VPN tunnel endpoint for the mobile client
- expose provider-native payloads directly to the app unless explicitly modeled in this spec

The app resolves a host through Relay, then connects to that host itself over the selected network provider's reachability layer.

## 4. High-Level Architecture

### 4.1 Actors

- `Relay Mobile App`: iOS client in this repository.
- `Relay Server`: product backend defined by this spec.
- `Relay Identity Provider`: whichever auth system Relay uses for its own sign-in.
- `Tailscale OAuth / API`: first external provider integration.
- `Remote Peer`: a device reachable over the selected tailnet and later accessed over SSH.

### 4.2 Trust Boundaries

- The mobile app trusts Relay as its product backend.
- Relay trusts external providers only through verified OAuth tokens and provider APIs.
- The remote SSH session is between the app and the remote peer, not between the peer and Relay.

### 4.3 Required Outcome

For a signed-in Relay user, the server must make it possible to:

1. Link a Tailscale account to the Relay account.
2. Discover tailnets available through that linked account.
3. Choose one active tailnet.
4. List peers in that tailnet.
5. Resolve one peer into a usable SSH host definition.

## 5. App-Facing Domain Model

These models are not optional. The current app decodes these shapes directly.

### 5.1 RelayAccountSummary

```json
{
  "id": "acct_123",
  "email": "user@example.com",
  "displayName": "Jane Smith"
}
```

Fields:

- `id`: string, stable Relay account identifier
- `email`: string
- `displayName`: string

### 5.2 RelayUserSession

```json
{
  "accessToken": "relay_access_token",
  "account": {
    "id": "acct_123",
    "email": "user@example.com",
    "displayName": "Jane Smith"
  }
}
```

Fields:

- `accessToken`: string bearer token used on subsequent API requests
- `account`: `RelayAccountSummary`

### 5.3 MeshAccountSummary

Represents the linked external provider account.

```json
{
  "id": "tailscale-user-123",
  "displayName": "Jane Smith"
}
```

### 5.4 MeshNetworkSummary

Represents one network namespace the provider exposes. In Tailscale v1 this is a tailnet.

```json
{
  "id": "tailnet_abc",
  "name": "example.ts.net",
  "isActive": true
}
```

### 5.5 TailscaleProviderState

```json
{
  "linkedAccount": {
    "id": "tailscale-user-123",
    "displayName": "Jane Smith"
  },
  "networks": [
    {
      "id": "tailnet_abc",
      "name": "example.ts.net",
      "isActive": true
    }
  ]
}
```

Rules:

- `linkedAccount` is `null` when the Relay user has not linked Tailscale.
- `networks` may be empty.
- At most one network `MUST` have `isActive = true`.

### 5.6 PeerDevice

```json
{
  "id": "8C0E2F56-4EE2-492B-8F28-907C9F81D7B6",
  "providerIdentifier": "n123456CNTRL",
  "name": "macbook",
  "networkAddress": "100.101.102.103",
  "meshHostname": "macbook.example.ts.net",
  "sshUsername": "ryanbaker",
  "isOnline": true,
  "operatingSystem": "macOS",
  "ownerName": "Ryan Baker"
}
```

Rules:

- `id` `MUST` be a UUID string because the iOS client decodes it into `UUID`.
- `providerIdentifier` `MUST` be the provider's stable peer identifier used later by `/peers/resolve`.
- `networkAddress` `MUST` be a directly reachable provider-network address if one exists.
- `meshHostname` `MAY` be `null`.
- `sshUsername` `MUST` be Relay's best guess for the SSH username to prefill in the client.
- `isOnline` indicates whether the peer is currently reachable according to the provider.

### 5.7 Host

This is the final resolved endpoint returned to the app before the app opens SSH.

```json
{
  "id": "13F153B6-235A-43A3-9156-C0E2A5E1A4E3",
  "name": "macbook",
  "hostname": "macbook.example.ts.net",
  "port": 22,
  "username": "ryanbaker",
  "authentication": {
    "automatic": {}
  }
}
```

Rules:

- `id` `MUST` be a UUID string.
- `hostname` `MUST` be a value the app can connect to directly.
- `port` defaults to `22` in normal SSH usage.
- `username` `MUST` be the preferred SSH login name.
- `authentication` `MUST` be compatible with the current app's `SSHAuthenticationMode`.

For v1 server implementations, `authentication` `SHOULD` always be:

```json
{
  "automatic": {}
}
```

The server should not attempt to tell the app to use password material or private keys. Those are app-side concerns.

## 6. Authentication Model

Relay has two separate authentication domains:

1. `Relay authentication`
2. `Provider authentication`

They must remain separate.

### 6.1 Relay Authentication

Relay authentication establishes the user's Relay account and returns a Relay bearer token.

That bearer token is then used for all provider operations.

### 6.2 Provider Authentication

Provider authentication links an external account, in v1 Tailscale, to an existing Relay account.

Provider tokens are never sent to the mobile app. The app only receives Relay-shaped state and data.

## 7. Session And Token Rules

### 7.1 Relay Access Token

The server `MUST` issue a bearer token suitable for mobile API authentication.

Requirements:

- opaque token or JWT are both acceptable
- token must identify the Relay account
- token expiration is allowed
- expired or invalid tokens `MUST` produce `401 Unauthorized`

### 7.2 Provider Tokens

The server `MUST` store provider tokens server-side.

Requirements:

- encrypt at rest
- associate them with the Relay account and provider account linkage
- support refresh if the provider supports refresh tokens
- remove them when the user unlinks the provider

### 7.3 Logout

`POST /api/mobile/auth/logout` invalidates the Relay session from the server's perspective if the token format supports revocation or server-side session state.

If the chosen token scheme is stateless and cannot be revoked, the endpoint must still succeed from the app's perspective and the client will clear local state.

## 8. Required Persistence

At minimum the Relay server `MUST` persist:

- Relay user accounts
- Relay sessions or token validation material
- provider account link records
- encrypted provider access and refresh tokens
- available network records or enough metadata to reconstruct them
- active selected network per Relay account and provider
- audit data for major auth and provider-link events

Suggested tables or equivalent collections:

- `relay_accounts`
- `relay_sessions`
- `provider_links`
- `provider_tokens`
- `provider_network_selections`
- `provider_peer_cache`
- `audit_events`

Caching peer inventories is optional. The API behavior is not optional.

## 9. HTTP API

All JSON APIs `MUST`:

- use `Content-Type: application/json` when a body is present
- return `application/json`
- accept `Authorization: Bearer <token>` for authenticated routes

All error responses outside simple redirects `SHOULD` use:

```json
{
  "message": "Human-readable error message"
}
```

The iOS client explicitly looks for `message`.

### 9.1 Relay Sign-In Start

`GET /api/mobile/auth/relay/start?redirect_uri=<url>`

Purpose:

- start Relay-owned sign-in in a browser session

This route is opened directly in `ASWebAuthenticationSession`. It is not fetched as JSON by the app.

Behavior:

- validate `redirect_uri`
- start the Relay auth flow
- authenticate the user with Relay's identity system
- redirect the browser back to the mobile callback URL with a short-lived code

Required redirect shape:

```text
relay://callback/auth/relay?code=<authorization_code>
```

Rules:

- the `code` `MUST` be single use
- the `code` `MUST` expire quickly
- the server `MUST` reject unapproved redirect URIs

### 9.2 Relay Sign-In Exchange

`POST /api/mobile/auth/relay/exchange`

Request:

```json
{
  "code": "one_time_code"
}
```

Response:

```json
{
  "accessToken": "relay_access_token",
  "account": {
    "id": "acct_123",
    "email": "user@example.com",
    "displayName": "Jane Smith"
  }
}
```

Behavior:

- validate the one-time code
- create or load the Relay account
- issue a Relay access token
- return `RelayUserSession`

### 9.3 Relay Session Lookup

`GET /api/mobile/auth/session`

Authentication:

- Relay bearer token required

Response:

```json
{
  "id": "acct_123",
  "email": "user@example.com",
  "displayName": "Jane Smith"
}
```

Behavior:

- return the current Relay account summary
- return `401` if the token is invalid or expired

### 9.4 Relay Logout

`POST /api/mobile/auth/logout`

Authentication:

- Relay bearer token required

Response:

- `204 No Content` or `200` with an empty JSON body are both acceptable

Behavior:

- revoke or invalidate the session if supported
- unlinking external providers is not part of logout

### 9.5 Tailscale Provider State

`GET /api/mobile/providers/tailscale/state`

Authentication:

- Relay bearer token required

Response:

`TailscaleProviderState`

Behavior:

- if no Tailscale account is linked, return:

```json
{
  "linkedAccount": null,
  "networks": []
}
```

- if linked, return the linked provider account and all tailnets available to that account
- exactly zero or one returned networks may be active

### 9.6 Tailscale Connect Start

`POST /api/mobile/providers/tailscale/connect/start`

Authentication:

- Relay bearer token required

Request:

```json
{
  "redirect_uri": "relay://callback/auth/tailscale"
}
```

Response:

```json
{
  "authorization_url": "https://..."
}
```

Behavior:

- create a provider-link authorization attempt bound to the Relay account
- validate the redirect URI
- return a provider authorization URL

The app will open `authorization_url` in a browser session and expects the provider-link flow to end with:

```text
relay://callback/auth/tailscale?code=<authorization_code>
```

The `code` returned to the app here is a Relay-generated exchange code, not necessarily the provider's original OAuth code. That indirection is recommended because it keeps provider details and secrets server-side.

### 9.7 Tailscale Connect Exchange

`POST /api/mobile/providers/tailscale/connect/exchange`

Authentication:

- Relay bearer token required

Request:

```json
{
  "code": "one_time_code"
}
```

Response:

`TailscaleProviderState`

Behavior:

- validate the Relay-generated one-time code from the callback
- finalize Tailscale account linkage
- store provider tokens server-side
- fetch available tailnets
- return provider state

If exactly one tailnet is available and no active tailnet is selected yet, the app may immediately call the select endpoint. The server does not need to auto-select it, but may do so if it still returns a compliant state response.

### 9.8 Tailscale Unlink

`POST /api/mobile/providers/tailscale/unlink`

Authentication:

- Relay bearer token required

Response:

- `204 No Content` or `200` with empty JSON are acceptable

Behavior:

- delete the Tailscale linkage for the Relay account
- delete stored provider tokens
- clear the active selected tailnet for that provider

### 9.9 Select Active Tailnet

`POST /api/mobile/providers/tailscale/networks/select`

Authentication:

- Relay bearer token required

Request:

```json
{
  "tailnet_id": "tailnet_abc"
}
```

Response:

`TailscaleProviderState`

Behavior:

- verify that the specified tailnet belongs to the linked Tailscale account
- mark that tailnet active for the Relay account
- ensure all other returned tailnets are inactive

### 9.10 List Peers

`GET /api/mobile/providers/tailscale/peers?tailnet_id=<id>`

Authentication:

- Relay bearer token required

Response:

array of `PeerDevice`

Behavior:

- verify the Relay account is linked to Tailscale
- verify the requested tailnet is accessible to that linked account
- fetch peer inventory from Tailscale or a valid cache
- map provider-native peer records into `PeerDevice`

Mapping guidance:

- `id`: Relay-generated UUID stable enough for one response; a deterministic UUID derived from provider ID is preferred
- `providerIdentifier`: the stable Tailscale device/node identifier used for resolution
- `name`: device display name
- `networkAddress`: Tailscale IP or other best direct address
- `meshHostname`: MagicDNS hostname if available
- `sshUsername`: Relay's inferred SSH username
- `isOnline`: online status from provider
- `operatingSystem`: normalized OS label
- `ownerName`: provider account or node owner display name if available

### 9.11 Resolve Peer To SSH Endpoint

`POST /api/mobile/providers/tailscale/peers/resolve`

Authentication:

- Relay bearer token required

Request:

```json
{
  "peer_id": "n123456CNTRL",
  "tailnet_id": "tailnet_abc"
}
```

Response:

`Host`

Behavior:

- verify the peer belongs to the specified tailnet
- verify the Relay account is allowed to see that tailnet
- resolve the peer into the best SSH destination for the app

Resolution rules:

- prefer a stable mesh hostname when available
- otherwise return the network address
- return the best available SSH username hint
- return `authentication = { "automatic": {} }`
- return port `22` unless Relay has a verified reason to use another port

The server `MUST NOT` proxy the SSH session after resolution.

## 10. End-To-End Flows

### 10.1 Relay Sign-In Flow

1. App opens `GET /api/mobile/auth/relay/start?redirect_uri=relay://callback/auth/relay` in a web auth session.
2. Server authenticates the user with Relay identity.
3. Server redirects to `relay://callback/auth/relay?code=...`.
4. App extracts the code and posts it to `/api/mobile/auth/relay/exchange`.
5. Server returns `RelayUserSession`.
6. App stores the Relay access token locally and uses it for later API calls.

### 10.2 Tailscale Link Flow

1. App calls `POST /api/mobile/providers/tailscale/connect/start`.
2. Server returns `authorization_url`.
3. App opens that URL in a web auth session.
4. User completes Tailscale authorization.
5. Server redirects to `relay://callback/auth/tailscale?code=...`.
6. App exchanges the code at `/api/mobile/providers/tailscale/connect/exchange`.
7. Server stores provider tokens and returns `TailscaleProviderState`.

### 10.3 Browse Devices Flow

1. App calls `/api/mobile/providers/tailscale/state`.
2. If linked and a tailnet is active, app calls `/api/mobile/providers/tailscale/peers?tailnet_id=...`.
3. Server returns `PeerDevice[]`.
4. User selects a peer.
5. App calls `/api/mobile/providers/tailscale/peers/resolve`.
6. Server returns `Host`.
7. App opens SSH directly to that host.

## 11. Tailscale-Specific Implementation Guidance

This section is intentionally provider-specific because v1 requires Tailscale.

### 11.1 Account Linkage

The Relay server `MUST` maintain a distinct Tailscale provider-link record per Relay account.

That record `SHOULD` contain:

- Relay account ID
- provider name `tailscale`
- provider user/account ID
- provider display name
- encrypted access token
- encrypted refresh token if present
- token expiration metadata
- active selected tailnet ID
- created and updated timestamps

### 11.2 Tailnet Model

The app uses the generic term `network`, but in the Tailscale implementation this means `tailnet`.

The server `MUST` translate Tailscale terminology into Relay terminology at the API boundary:

- provider account -> `linkedAccount`
- tailnet -> `network`

### 11.3 Peer Resolution

The server should prefer endpoint values in this order:

1. MagicDNS hostname if valid and available
2. Tailscale IP address
3. another verified directly reachable hostname inside the tailnet

The endpoint returned must be something the iOS device can actually attempt to connect to directly.

### 11.4 SSH Username Inference

The provider usually cannot guarantee the correct SSH username. The server should treat this as a hint.

Acceptable sources for `sshUsername`:

- a provider profile field if one exists
- known owner name mappings maintained by Relay
- a configurable default such as the node's login name

If no good answer exists, the server should still return a reasonable default rather than failing peer discovery.

## 12. Error Handling

The mobile client behavior depends on a few specific rules.

### 12.1 Authentication Errors

- invalid or expired Relay bearer token `MUST` return `401`
- the app treats `401` as session expiration and signs the user out locally

### 12.2 Structured Error Body

Non-401 errors `SHOULD` include:

```json
{
  "message": "..."
}
```

Examples:

- `"Tailscale account is not linked."`
- `"Selected tailnet was not found."`
- `"Peer could not be resolved."`

### 12.3 Suggested Status Codes

- `400 Bad Request`: malformed request body or invalid query
- `401 Unauthorized`: missing or invalid Relay bearer token
- `403 Forbidden`: account cannot access the requested provider resource
- `404 Not Found`: requested tailnet or peer does not exist
- `409 Conflict`: code already exchanged or provider link already exists in an incompatible state
- `422 Unprocessable Entity`: semantically invalid input
- `500 Internal Server Error`: unexpected server failure
- `502/503/504`: upstream provider failure or outage

## 13. Security Requirements

### 13.1 Redirect URI Validation

The server `MUST` maintain an allowlist of accepted mobile callback URIs or callback URI patterns.

At minimum v1 should accept:

- `relay://callback/auth/relay`
- `relay://callback/auth/tailscale`

Do not reflect arbitrary redirect URIs.

### 13.2 Authorization Codes

All auth exchange codes `MUST` be:

- short lived
- single use
- bound to the correct flow
- resistant to guessing

### 13.3 Provider Tokens

Provider tokens `MUST`:

- never be returned to the app
- be encrypted at rest
- be redacted from logs

### 13.4 Least Privilege

The Tailscale integration should request only the scopes needed to:

- identify the linked user/account
- list available tailnets
- list peers within a selected tailnet
- resolve peer addressing metadata

### 13.5 Auditability

The server `SHOULD` audit:

- Relay sign-in success/failure
- provider link/unlink events
- tailnet selection changes
- upstream provider token refresh failures

Do not log secrets, raw bearer tokens, or provider access tokens.

## 14. Versioning And Extensibility

The current app is built around `/api/mobile/...` paths and a generic mesh-provider abstraction. The server must preserve that direction.

To keep the system extensible:

- Relay-owned auth endpoints remain provider-agnostic
- provider routes live under `/api/mobile/providers/<provider>`
- app-facing shapes remain generic where possible
- provider-native terminology stays behind the server boundary

If additional providers are added later, they should implement the same conceptual lifecycle:

1. linked account state
2. selectable networks
3. peer listing
4. endpoint resolution

## 15. Observability

The implementation `SHOULD` emit metrics for:

- Relay sign-in starts, successes, failures
- provider link starts, successes, failures
- tailnet selection changes
- peer list request latency
- resolve request latency
- provider upstream error rate

Recommended structured log fields:

- `relay_account_id`
- `provider`
- `provider_account_id`
- `tailnet_id`
- `peer_id`
- `request_id`
- `outcome`

## 16. Acceptance Criteria

An implementation is correct for v1 if all of the following are true:

- a new user can sign in to Relay from the iOS app
- the app can restore an existing Relay session through `/api/mobile/auth/session`
- the user can link a Tailscale account through the browser-based flow
- `/api/mobile/providers/tailscale/state` returns compliant state for both linked and unlinked accounts
- the user can select an active tailnet
- the app can list peers for the active tailnet
- the app can resolve a peer into a `Host`
- the app can then connect directly to that host over SSH without the server proxying the connection
- expired Relay tokens return `401`
- non-401 backend errors return a JSON `message`

## 17. Explicit Client Contract Reference

This spec is derived from the current iOS client implementation in:

- `Relay/Relay/RelayBackendClient.swift`
- `Relay/Relay/RelayAuthManager.swift`
- `Relay/Relay/MeshProvider.swift`
- `Relay/Relay/PeerDevice.swift`
- `Relay/Relay/Host.swift`

If the server implementation and this document diverge, the mobile client contract is currently the source of truth for v1 behavior.
