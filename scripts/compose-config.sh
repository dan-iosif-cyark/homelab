#!/usr/bin/env bash
# Validate each stack with `docker compose config`, interpolating from its
# .env.template. Each stack is copied to a scratch dir first so that a real
# .env is never read or written, and `env_file: .env` still resolves.
#
# Usage: scripts/compose-config.sh <stack>/compose.yaml...
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

status=0
for compose in "$@"; do
	stack=$(dirname "$compose")
	work="$scratch/$(basename "$stack")"
	mkdir -p "$work"
	cp -R "$stack/." "$work/"
	rm -f "$work/.env"
	if [[ -f "$stack/.env.template" ]]; then
		cp "$stack/.env.template" "$work/.env"
	else
		touch "$work/.env"
	fi

	if ! docker compose --project-directory "$work" --file "$work/compose.yaml" config --quiet; then
		echo "error: $compose failed to render" >&2
		status=1
	fi
done

exit "$status"
