# Heartbeat Network Options and Configurations

This doc lays out the practical network permutations for running Heartbeat
(FreeTAKServer) and connecting phones in the field. The key invariant is:

- Every phone must be able to reach the server at `SERVER_IP:COT_PORT` over TCP.

If there is no IP path, TAK will not connect.

## Glossary (quick)
- Server: the machine running Heartbeat + FreeTAKServer
- Client: iTAK/ATAK on a phone/tablet
- CoT: Cursor-on-Target data stream (default TCP 8087)
- SSL CoT: TLS-encrypted CoT (default TCP 8089)
- DP: DataPackage service (default TCP 8443)
- API: FreeTAKServer REST API (default TCP 19023)

## Axes of configuration (what can vary)

1) Server location
- S1: Laptop / mini-PC on-site
- S2: Rugged box in vehicle (same as S1, different power/placement)
- S3: Cloud VM with public IP

2) Client access network
- C1: Same Wi-Fi LAN as server
- C2: Same wired LAN (Ethernet + Wi-Fi AP)
- C3: Cellular (5G/LTE)
- C4: Satellite (Starlink/other)
- C5: MANET radio network (IP-capable)
- C6: Ad-hoc hotspot on a router/AP

3) Internet / reachability
- R1: No internet (offline local LAN)
- R2: Public IP + port forwarding allowed
- R3: No public IP (CGNAT / locked router)

4) Traversal technique (if R3)
- T1: Mesh VPN (Tailscale/ZeroTier/WireGuard)
- T2: Reverse tunnel to a public server (ssh tunnel, cloud relay)

5) Transport
- P1: CoT over TCP (8087)
- P2: SSL CoT over TCP (8089)

6) Enrollment / distribution
- D1: Package served locally (`./heartbeat serve`)
- D2: Pre-generated packages copied to phones
- D3: Manual server entry (IP + port)

## Practical combinations (common patterns)

Each scenario below is a valid permutation of the axes above.

### A) Same-network local ops (easiest)

A1) Local Wi-Fi bubble (no internet)
- Axes: S1 + C1 + R1 + P1 + D1
- Works: Yes
- Requirements:
  - Server and phones on same Wi-Fi
  - No client isolation on the Wi-Fi
- Steps:
  1) `./heartbeat start`
  2) `./heartbeat serve`
  3) Phones open `http://SERVER_IP:9000` and import package

A2) Wired LAN + AP
- Axes: S1 + C2 + R1 + P1 + D1
- Same as A1, but server is wired and phones use the same LAN via AP

A3) Same Wi-Fi but AP isolates clients
- Axes: S1 + C1 + R1
- Works: No
- Symptom: Phones cannot reach server or each other
- Fix: Disable client isolation or use a different AP

### B) Public server (works anywhere with data)

B1) Cloud VM with public IP
- Axes: S3 + C3 + R2 + P1 or P2 + D2/D3
- Works: Yes
- Requirements:
  - VM has public IPv4
  - Ports open: 8087 (required), optional 8089/9000
- Steps:
  1) Deploy on VM, set `SERVER_IP` to public IP
  2) Phones connect over 5G using public IP

B2) Cloud VM + SSL CoT
- Axes: S3 + C3 + R2 + P2
- Works: Yes, better security
- Requirements:
  - Certificates set up
  - Phones configured for SSL CoT

### C) Laptop server with public IP (only if port forwarding allowed)

C1) Home/office with router port forward
- Axes: S1 + C3 + R2 + P1
- Works: Yes
- Requirements:
  - Router forwards TCP 8087 to server IP
  - Public IP (not CGNAT)
- Notes:
  - If router controls are unavailable, this will not work

### D) Locked networks / CGNAT (no router control)

D1) Mesh VPN overlay
- Axes: S1 + C3 + R3 + T1 + P1
- Works: Yes
- Requirements:
  - VPN app installed on server + phones
  - Use VPN IP as `SERVER_IP`
- Notes:
  - This is the easiest no-router-control option

D2) Reverse tunnel to a public relay
- Axes: S1 + C3 + R3 + T2 + P1
- Works: Yes
- Requirements:
  - Public relay server
  - Tunnel forwards a public TCP port to local 8087

### E) MANET radio networks (IP-capable radios)

E1) IP-capable MANET, server on the mesh
- Axes: S1 + C5 + R1 + P1
- Works: Yes
- Requirements:
  - Radios provide an IP network
  - Phones connect to the mesh (via radio Wi-Fi or gateway)

E2) MANET with gateway to cloud server
- Axes: S3 + C5 + R2 + P1
- Works: Yes if the gateway provides internet
- Requirements:
  - Gateway routes mesh traffic to the internet
  - Latency may be higher

E3) Voice-only radios
- Axes: N/A
- Works: No
- Why: Voice-only radios do not carry IP data, so TAK cannot connect

### F) Satellite backhaul

F1) Starlink/other sat link to a public server
- Axes: S3 + C4 + R2 + P1
- Works: Yes
- Notes:
  - Usually higher latency; still usable for location tracking

F2) Local server + satellite backhaul for command post
- Axes: S1 + C1 + R1 (local) + optional sat for upstream reporting
- Works: Yes (phones still use local Wi-Fi)

## Configuration patterns in Heartbeat

### Set the server address for clients
- `SERVER_IP` must be the address phones can reach (local or public)
- `COT_PORT` is the TCP port clients connect to (default 8087)

### Minimal client onboarding
- Generate a package: `./heartbeat package "First Last"`
- Serve packages: `./heartbeat serve`
- On phone: open `http://SERVER_IP:9000`

## Connectivity checklist (fast triage)

1) Can a phone reach the server IP?
- Same Wi-Fi: open `http://SERVER_IP:9000` after `./heartbeat serve`
- Public: open `http://PUBLIC_IP:9000` from cellular

2) Is TCP 8087 open?
- Required for TAK clients
- Firewalls often block it

3) Is the Wi-Fi isolated?
- Guest networks often block device-to-device traffic

## Security notes (simple)
- If you expose a public IP, you are open to the internet.
- For higher security, use SSL CoT (8089) and stronger credentials.
- Lowest friction is not the most secure; choose based on threat model.

## Recommendation by environment

- Office / training: A1 (same Wi-Fi)
- Field with MANET IP radios: E1
- Field with cellular coverage, no router control: D1 (mesh VPN) or B1 (public VM)
- No infrastructure at all: A1 with a portable router + local server
