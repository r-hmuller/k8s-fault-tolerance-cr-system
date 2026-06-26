#!/bin/bash
set -e

PLAYBOOK="run-tests.yaml"

if [ -z "$1" ]; then
  echo "Usage: $0 <num_clients>"
  echo "Example: $0 5"
  exit 1
fi

CLIENTS="$1"
INVENTORY="inventory-${CLIENTS}clients.yaml"

if [ ! -f "$INVENTORY" ]; then
  echo "Error: inventory file '$INVENTORY' not found."
  exit 1
fi

echo "========================================"
echo "Running with $CLIENTS client(s) — $INVENTORY"
echo "========================================"
NUM_CLIENT=$CLIENTS ansible-playbook -v -i "$INVENTORY" "$PLAYBOOK"
echo "Round $CLIENTS finished."
