# Oracle Cloud Always Free VM (Public Internet)

This guide shows how to run Heartbeat on a free Oracle Cloud VM so phones can
connect over the internet (5G/LTE). The VM must have a public IPv4 address.

## 0) Know the limits (Always Free)

Oracle Free Tier includes Always Free resources and a time-limited free trial.
Always Free compute is limited (for example, up to 4 OCPUs and 24 GB memory
across Ampere A1 instances). Always Free compute must be created in your home
region, and you may hit "out of host capacity" errors at times.

## 1) Create the VM

From the Oracle Cloud Console:

1) Create a Compute Instance.
2) Pick your home region and availability domain.
3) Choose an Always Free shape:
   - VM.Standard.A1.Flex (Arm) or VM.Standard.E2.1.Micro (x86)
4) Select an Ubuntu image (recommended for this repo's deploy script).
5) Add your SSH public key and create the instance.

If you get "out of host capacity", try another availability domain or wait.

## 2) Open inbound ports in the VCN

By default, the security list only allows inbound SSH (port 22). You must add
stateful ingress rules for the TAK ports. Without security rules, inbound
traffic to your VM is blocked.

Add these TCP ingress rules (source 0.0.0.0/0):
- 22   (SSH)
- 8087 (TAK CoT)
- 8089 (SSL CoT, optional)
- 9000 (Package download page, optional)
- 19023 (API, optional)

## 3) Deploy Heartbeat on the VM

SSH to the VM:
```bash
ssh ubuntu@<public-ip>
```

Then run:
```bash
git clone <your-repo-url> heartbeat
cd heartbeat
TEAM_NAME="My Team" PUBLIC_IP="$(curl -s ifconfig.me)" ./deploy_public_vm.sh
```

This installs Docker, sets the server IP to your public IP, and starts the
TAK server.

## 4) Connect phones over the internet

On each phone (5G/LTE):
- Server: <public-ip>
- Port: 8087
- Protocol: TCP

Or:
```bash
./heartbeat serve
```
Then open `http://<public-ip>:9000` on the phone and import the package.

## 5) Bulk-create users (optional)

```bash
./heartbeat addusers names.txt
```
One full name per line. Password defaults to the name.

## Troubleshooting

- Can SSH but phones cannot connect:
  - Check security list ingress rules and ensure 8087 is open.
  - Ensure the VM has a public IPv4.
- "Out of host capacity" when creating the VM:
  - Try a different availability domain or wait.
