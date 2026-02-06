#!/usr/bin/env bash
# Backend Interface Definition
# All backends must implement these functions.

# Required: Lifecycle
backend_install() { :; }      # Install/setup the TAK server
backend_start() { :; }        # Start the server
backend_stop() { :; }         # Stop the server
backend_status() { :; }       # Show server status (return 0=running, 1=stopped)
backend_logs() { :; }         # Show/stream logs ($1 = "-f" for follow)
backend_update() { :; }       # Update to latest version
backend_uninstall() { :; }    # Remove the server

# Required: Info
backend_get_ports() { :; }    # Echo required ports
backend_name() { :; }         # Echo backend name (e.g., "FreeTAKServer")

# Required: Packages
backend_get_package() { :; }  # Generate connection package ($1 = username)

# Capabilities: return 0=yes, 1=no
backend_supports() {
    local cap="$1"
    case "$cap" in
        ssl|users|webmap|federation) return 1 ;;  # Override in backend
        *) return 1 ;;
    esac
}
