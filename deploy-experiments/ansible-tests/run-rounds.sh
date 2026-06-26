#!/bin/bash
set -e

PLAYBOOK="run-tests.yaml"

ROUNDS=(
  "inventory-5clients.yaml"
  "inventory-6clients.yaml"
)

CLIENTS_PER_ROUND=(5)

for i in "${!ROUNDS[@]}"; do
  CLIENTS="${CLIENTS_PER_ROUND[$i]}"
  INVENTORY="${ROUNDS[$i]}"
  echo "========================================"
  echo "Round $CLIENTS: running with $CLIENTS client(s) — $INVENTORY"
  echo "========================================"
  NUM_CLIENT=$CLIENTS ansible-playbook -i "$INVENTORY" "$PLAYBOOK"
  echo "Round $CLIENTS finished."
  echo ""
done

echo "All rounds completed."
