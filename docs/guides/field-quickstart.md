# Field Quick Start (One-Page)

Goal: get everyone's phone sharing live location on the same map, fast.

> **No logins required.** Heartbeat uses TCP connections - just scan the QR and connect. No usernames, no passwords, no friction.

## 1) Start the server
```bash
./setup.sh --docker --interactive
./heartbeat start
```

## 2) Get the server address
```bash
./heartbeat info
```
Use the **Server IP** shown.

## 3) Distribute connection
Option A (recommended):
```bash
./heartbeat serve
```
Phones open: `http://SERVER_IP:9000` -> download zip -> import into iTAK/ATAK.

Option B (manual):
- Server: `SERVER_IP`
- Port: `8087`
- Protocol: TCP

## 4) Confirm it's working
```bash
./heartbeat listen
```
You should see connections and data events.

---

# Network reality check (fast)

## Same Wi-Fi (easiest)
- All phones + server on same Wi-Fi
- Works with no internet

## Internet hosting (when phones are on 5G)
- Server must be reachable from the public internet
- If you don't control the router or inbound ports, **hosting from a work laptop usually won't work**
- Alternatives:
  - Public VM (works anywhere)
  - Mesh VPN (Tailscale/ZeroTier) for no-router setups

If you tell me your environment (work network rules, phone coverage), we can pick the best path.
