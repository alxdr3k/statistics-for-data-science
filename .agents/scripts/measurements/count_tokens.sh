#!/usr/bin/env bash
exec python3 "$(dirname "$0")/measurement.py" count-tokens "$@"
