#!/usr/bin/env bash
# End-to-end Oracle Always Free VM deploy for Heartbeat.
# Requires: oci CLI configured, SSH key, and a compartment OCID.
#
# Usage:
#   OCI_COMPARTMENT_OCID=ocid1.compartment... \
#   OCI_SSH_PUBLIC_KEY=$HOME/.ssh/id_ed25519.pub \
#   HEARTBEAT_REPO_URL=git@github.com:you/heartbeat.git \
#   TEAM_NAME="My Team" \
#   ./deploy_oracle_free_vm.sh
#
# Optional:
#   OCI_AVAILABILITY_DOMAIN=xxxxx:PHX-AD-1
#   OCI_SHAPE=VM.Standard.E2.1.Micro
#   OCI_SUBNET_OCID=ocid1.subnet...
#   NAMES_FILE=/path/to/names.txt

set -euo pipefail

TEAM_NAME="${TEAM_NAME:-Volunteer FD}"
HEARTBEAT_REPO_URL="${HEARTBEAT_REPO_URL:-}"
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-}"
OCI_AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN:-}"
OCI_SHAPE="${OCI_SHAPE:-VM.Standard.E2.1.Micro}"
OCI_SSH_PUBLIC_KEY="${OCI_SSH_PUBLIC_KEY:-}"
OCI_SUBNET_OCID="${OCI_SUBNET_OCID:-}"
INSTANCE_NAME="${INSTANCE_NAME:-heartbeat-vm}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.0.0/24}"
SSH_USER="${SSH_USER:-ubuntu}"
NAMES_FILE="${NAMES_FILE:-}"

log() { echo "[oracle-deploy] $*"; }
die() { echo "[oracle-deploy] error: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! need_cmd oci; then
    die "oci CLI not found. Install and configure it first."
fi

if [[ -z "$OCI_COMPARTMENT_OCID" ]]; then
    die "Set OCI_COMPARTMENT_OCID and rerun."
fi

if [[ -z "$OCI_SSH_PUBLIC_KEY" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        OCI_SSH_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub"
    elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
        OCI_SSH_PUBLIC_KEY="$HOME/.ssh/id_rsa.pub"
    else
        die "Set OCI_SSH_PUBLIC_KEY to your SSH public key file."
    fi
fi

if [[ -z "$HEARTBEAT_REPO_URL" ]]; then
    if need_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        HEARTBEAT_REPO_URL="$(git config --get remote.origin.url || true)"
    fi
fi
if [[ -z "$HEARTBEAT_REPO_URL" ]]; then
    die "Set HEARTBEAT_REPO_URL so the VM can clone the repo."
fi

if [[ -z "$OCI_AVAILABILITY_DOMAIN" ]]; then
    OCI_AVAILABILITY_DOMAIN="$(oci iam availability-domain list \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --query 'data[0].name' --raw-output)"
fi

log "Using AD: $OCI_AVAILABILITY_DOMAIN"

create_security_list() {
    local vcn_id="$1"
    local sec_list_id
    local rules_file
    rules_file="$(mktemp)"
    cat > "$rules_file" <<'JSON'
[
  {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
  {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":8087,"max":8087}}},
  {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":8089,"max":8089}}},
  {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":9000,"max":9000}}},
  {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
   "tcpOptions":{"destinationPortRange":{"min":19023,"max":19023}}}
]
JSON

    sec_list_id="$(oci network security-list create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --vcn-id "$vcn_id" \
        --display-name "heartbeat-sec" \
        --ingress-security-rules "file://$rules_file" \
        --egress-security-rules '[{"protocol":"all","destination":"0.0.0.0/0","isStateless":false}]' \
        --query 'data.id' --raw-output)"

    rm -f "$rules_file"
    echo "$sec_list_id"
}

ensure_network() {
    if [[ -n "$OCI_SUBNET_OCID" ]]; then
        echo "$OCI_SUBNET_OCID"
        return
    fi

    local suffix
    suffix="$(date +%s)"
    local vcn_id igw_id rt_id sec_id subnet_id

    vcn_id="$(oci network vcn create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --cidr-block "$VCN_CIDR" \
        --display-name "heartbeat-vcn-$suffix" \
        --dns-label "hbvcn$suffix" \
        --query 'data.id' --raw-output)"

    igw_id="$(oci network internet-gateway create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --vcn-id "$vcn_id" \
        --is-enabled true \
        --display-name "heartbeat-igw-$suffix" \
        --query 'data.id' --raw-output)"

    rt_id="$(oci network route-table create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --vcn-id "$vcn_id" \
        --display-name "heartbeat-rt-$suffix" \
        --route-rules \"[{\\\"cidrBlock\\\":\\\"0.0.0.0/0\\\",\\\"networkEntityId\\\":\\\"$igw_id\\\"}]\" \
        --query 'data.id' --raw-output)"

    sec_id="$(create_security_list "$vcn_id")"

    subnet_id="$(oci network subnet create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --vcn-id "$vcn_id" \
        --cidr-block "$SUBNET_CIDR" \
        --display-name "heartbeat-subnet-$suffix" \
        --dns-label "hbsubnet$suffix" \
        --availability-domain "$OCI_AVAILABILITY_DOMAIN" \
        --route-table-id "$rt_id" \
        --security-list-ids \"[\\\"$sec_id\\\"]\" \
        --prohibit-public-ip-on-vnic false \
        --query 'data.id' --raw-output)"

    echo "$subnet_id"
}

attach_security_list() {
    local subnet_id="$1"
    local vcn_id
    vcn_id="$(oci network subnet get --subnet-id "$subnet_id" \
        --query 'data."vcn-id"' --raw-output)"
    local sec_id
    sec_id="$(create_security_list "$vcn_id")"

    local tmp1 tmp2
    tmp1="$(mktemp)"
    tmp2="$(mktemp)"
    oci network subnet get --subnet-id "$subnet_id" \
        --query 'data."security-list-ids"' --output json > "$tmp1"

    python3 - "$tmp1" "$sec_id" > "$tmp2" <<'PY'
import json, sys
path, new_id = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    ids = json.load(f)
if new_id not in ids:
    ids.append(new_id)
print(json.dumps(ids))
PY

    oci network subnet update --subnet-id "$subnet_id" \
        --security-list-ids "$(cat "$tmp2")" >/dev/null

    rm -f "$tmp1" "$tmp2"
}

log "Preparing network..."
subnet_id="$(ensure_network)"

if [[ -n "$OCI_SUBNET_OCID" ]]; then
    attach_security_list "$subnet_id"
fi

log "Finding Ubuntu image..."
image_id="$(oci compute image list \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "$OCI_SHAPE" \
    --query 'data | sort_by(@, &"time-created")[-1].id' \
    --raw-output)"

[[ -n "$image_id" && "$image_id" != "null" ]] || die "Could not find a matching Ubuntu image."

log "Launching instance..."
shape_args=()
if [[ "$OCI_SHAPE" == VM.Standard.A1.Flex* ]]; then
    shape_args+=(--shape-config '{"ocpus":1,"memory-in-gbs":6}')
fi

instance_id="$(oci compute instance launch \
    --availability-domain "$OCI_AVAILABILITY_DOMAIN" \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --display-name "$INSTANCE_NAME" \
    --shape "$OCI_SHAPE" \
    "${shape_args[@]}" \
    --subnet-id "$subnet_id" \
    --assign-public-ip true \
    --image-id "$image_id" \
    --ssh-authorized-keys-file "$OCI_SSH_PUBLIC_KEY" \
    --query 'data.id' --raw-output)"

log "Waiting for instance to be RUNNING..."
for _ in $(seq 1 60); do
    state="$(oci compute instance get --instance-id "$instance_id" \
        --query 'data."lifecycle-state"' --raw-output)"
    if [[ "$state" == "RUNNING" ]]; then
        break
    fi
    sleep 10
done

public_ip=""
for _ in $(seq 1 30); do
    public_ip="$(oci compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0]."public-ip"' --raw-output)"
    if [[ -n "$public_ip" && "$public_ip" != "null" ]]; then
        break
    fi
    sleep 5
done

[[ -n "$public_ip" && "$public_ip" != "null" ]] || die "Failed to get public IP."
log "Instance public IP: $public_ip"

log "Deploying Heartbeat on the VM..."
ssh -o StrictHostKeyChecking=no "$SSH_USER@$public_ip" \
    "git clone \"$HEARTBEAT_REPO_URL\" heartbeat && cd heartbeat && TEAM_NAME=\"$TEAM_NAME\" PUBLIC_IP=\"$public_ip\" ./deploy_public_vm.sh"

if [[ -n "$NAMES_FILE" ]]; then
    log "Uploading names file and creating users..."
    scp -o StrictHostKeyChecking=no "$NAMES_FILE" "$SSH_USER@$public_ip:/tmp/names.txt"
    ssh -o StrictHostKeyChecking=no "$SSH_USER@$public_ip" \
        "cd heartbeat && ./heartbeat addusers /tmp/names.txt"
fi

echo ""
log "Done."
echo "Server: $public_ip"
echo "CoT: 8087/tcp"
echo "Use: http://$public_ip:9000  (after ./heartbeat serve on the VM)"
