#!/usr/bin/env bash
cd "$(dirname "$0")"
watch -n 60 './nmt.sh all compact && python3 plot_nmt.py'