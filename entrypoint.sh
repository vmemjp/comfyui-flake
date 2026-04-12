#!/bin/bash
set -euo pipefail

if [ "${COMFYUI_EGRESS:-allow}" = "block" ]; then
    echo "EGRESS BLOCKED: container-initiated outbound connections are disabled."
    echo "                Host API/UI access still works (inbound + established responses)."
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -j DROP
fi

exec /app/.venv/bin/python main.py --listen 0.0.0.0 "$@"
