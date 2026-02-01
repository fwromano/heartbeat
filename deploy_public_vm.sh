#!/usr/bin/env bash
# One-shot public VM deploy for Heartbeat (Docker).
# Usage:
#   TEAM_NAME="My Team" HEARTBEAT_REPO_URL="git@github.com:you/heartbeat.git" ./deploy_public_vm.sh
#   PUBLIC_IP=1.2.3.4 ./deploy_public_vm.sh
# Optional:
#   NAMES_FILE=/path/to/names.txt  (one full name per line)

set -euo pipefail

TEAM_NAME="${TEAM_NAME:-Volunteer FD}"
PUBLIC_IP="${PUBLIC_IP:-}"
HEARTBEAT_REPO_URL="${HEARTBEAT_REPO_URL:-}"
HEARTBEAT_DIR="${HEARTBEAT_DIR:-}"
NAMES_FILE="${NAMES_FILE:-}"

log() { echo "[deploy] $*"; }
die() { echo "[deploy] error: $*" >&2; exit 1; }

SUDO=""
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        die "Run as root or install sudo."
    fi
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

install_packages() {
    if need_cmd apt-get; then
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq docker.io docker-compose-plugin git curl
    else
        die "This script currently supports Debian/Ubuntu (apt-get)."
    fi
}

ensure_docker() {
    if ! need_cmd docker; then
        log "Installing Docker + dependencies..."
        install_packages
    fi
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
}

fetch_public_ip() {
    if [[ -n "$PUBLIC_IP" ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    if need_cmd curl; then
        PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    fi
    if [[ -z "$PUBLIC_IP" ]] && need_cmd curl; then
        PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    [[ -n "$PUBLIC_IP" ]] || die "Could not determine public IP; set PUBLIC_IP=... and rerun."
    echo "$PUBLIC_IP"
}

ensure_repo() {
    if [[ -n "$HEARTBEAT_DIR" ]]; then
        [[ -d "$HEARTBEAT_DIR" ]] || die "HEARTBEAT_DIR not found: $HEARTBEAT_DIR"
        echo "$HEARTBEAT_DIR"
        return
    fi

    if [[ -f "./setup.sh" && -f "./heartbeat" ]]; then
        echo "$(pwd)"
        return
    fi

    [[ -n "$HEARTBEAT_REPO_URL" ]] || die "Set HEARTBEAT_REPO_URL or run from the repo directory."
    local dest="$HOME/heartbeat"
    if [[ -d "$dest/.git" ]]; then
        log "Updating repo in $dest"
        (cd "$dest" && git pull --rebase)
    else
        log "Cloning repo to $dest"
        git clone "$HEARTBEAT_REPO_URL" "$dest"
    fi
    echo "$dest"
}

open_firewall_if_active() {
    if need_cmd ufw; then
        local status
        status=$(ufw status | head -1 | awk '{print $2}')
        if [[ "$status" == "active" ]]; then
            log "UFW active; opening required ports"
            $SUDO ufw allow 8087/tcp >/dev/null
            $SUDO ufw allow 8089/tcp >/dev/null
            $SUDO ufw allow 19023/tcp >/dev/null
            $SUDO ufw allow 9000/tcp >/dev/null
        fi
    fi
}

main() {
    ensure_docker

    local repo_dir
    repo_dir=$(ensure_repo)

    local ip
    ip=$(fetch_public_ip)
    log "Public IP: $ip"

    open_firewall_if_active

    log "Running setup..."
    (cd "$repo_dir" && ./setup.sh --docker --team "$TEAM_NAME" --server-ip "$ip")

    log "Starting server..."
    (cd "$repo_dir" && ./heartbeat start)

    if [[ -n "$NAMES_FILE" ]]; then
        log "Creating users from $NAMES_FILE"
        (cd "$repo_dir" && ./heartbeat addusers "$NAMES_FILE")
    fi

    echo ""
    log "Done."
    echo "Public server: $ip"
    echo "CoT port: 8087/tcp"
    echo "Use: ./heartbeat serve  # to host packages on :9000"
    echo ""
    echo "IMPORTANT: Open these ports in your cloud security group/firewall:"
    echo "  8087/tcp (required), 8089/tcp (optional SSL), 9000/tcp (optional), 19023/tcp (optional)"
}

main "$@"
