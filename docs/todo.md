# TODO (Ordered by Urgency)

## Urgent
- Lock down public exposure: do not open 19023/8087/8089 to the world by default; add VPN-only option (Tailscale CIDR allowlist) and document it.
- Fix weak default credentials for any public deployment path; keep name=name only for private/VPN deployments.

## High
- Make Oracle deploy script idempotent (reuse VCN/subnet, handle existing repo on VM).
- Add dependency checks in deploy scripts (python3 for subnet security list update).

## Medium
- Improve SSH hardening in deploy scripts (avoid StrictHostKeyChecking=no or document risk).
- Handle DataPackage port conflicts more explicitly (warn + disable or remap).
