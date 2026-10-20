#!/usr/bin/env bash
# Usage: scripts/traffic.sh <env> [duration-seconds] [extra traffic.py args...]
# Runs scripts/traffic/traffic.py as a Job inside <env>, waits for it and
# prints the summary. Exit status mirrors the generator (non-zero = failures).
source "$(dirname "$0")/lib.sh"

env=${1:-prod}
duration=${2:-90}
shift $(($# >= 2 ? 2 : $#))
valid_env "$env"
require_cluster

traffic_start "$env" "$duration" "$@"
traffic_wait "$env"
