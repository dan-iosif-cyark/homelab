#!/usr/bin/env bash
# Deploy the stacks from this clone, on the Unraid server. Compose Manager Plus
# keeps running them: its project folders point here through `indirect` files,
# and keep their own project_name and autostart.
#
# Usage:
#   scripts/deploy.sh link <stack>...
#   scripts/deploy.sh up [--no-pull] [<stack>...]
#
# `link` points the plugin's folder for each stack at this clone, and moves the
# folder's own compose.yaml and .env aside.
#
# `up` pulls main, renders each stack's .env from 1Password, checks every stack
# renders, then runs `docker compose up` in stack order. A service whose
# config/<service>/ changed in the pull is restarted, since it only reads its
# config at start. With no stacks named, every linked stack set to autostart is
# deployed.
#
# Environment:
#   PROJECTS       the plugin's project folders
#   OP_TOKEN_FILE  the 1Password service account token
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
projects=${PROJECTS:-/boot/config/plugins/compose.manager/projects}
op_token_file=${OP_TOKEN_FILE:-/boot/config/homelab/op-token}

# Kept current by Renovate.
op_image=1password/op:2.39.0@sha256:3cd5a1febc662c93d46b944b983b301e710da5c016ef63be9d436cf2b1ed30d5
git_image=alpine/git:v2.54.0@sha256:ae0f6f4bce38d2b8c40becc0d6241a08d9f57186ea03029de2189a2b5e722d94

log() { printf '%s\n' "$*"; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Unraid may not ship git; run it in a container if so.
git() {
	if type -P git >/dev/null; then
		command git "$@"
	else
		docker run --rm --volume "$repo:$repo" "$git_image" "$@"
	fi
}

# Accepts `2_identity`, `2_identity/` or a path ending in the stack folder.
stack_name() {
	local name=${1%/}
	name=${name##*/}
	[[ -f $repo/$name/compose.yaml ]] || die "no stack called $name in $repo"
	printf '%s' "$name"
}

is_linked() {
	local indirect=$projects/$1/indirect
	[[ -f $indirect && $(<"$indirect") == "$repo/$1" ]]
}

is_autostart() {
	local autostart=$projects/$1/autostart
	[[ -f $autostart && $(<"$autostart") == true ]]
}

# The same files and project name the plugin passes, so both manage one project.
compose() {
	local dir=$repo/$1 project=$projects/$1
	shift
	local -a args=(--project-name "$(<"$project/project_name")" --file "$dir/compose.yaml")
	if [[ -f $project/compose.override.yaml ]]; then
		args+=(--file "$project/compose.override.yaml")
	fi
	if [[ -f $dir/.env ]]; then
		args+=(--env-file "$dir/.env")
	fi
	docker compose "${args[@]}" "$@"
}

render_env() {
	local dir=$repo/$1 tmp
	[[ -f $dir/.env.template ]] || return 0
	tmp=$(mktemp "$dir/.env.XXXXXX") # mode 600, and gitignored
	if ! docker run --rm --interactive --env OP_SERVICE_ACCOUNT_TOKEN "$op_image" \
		op inject <"$dir/.env.template" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$dir/.env"
}

# Restart the services whose config/<service>/ changed between two commits.
restart_changed() {
	local stack=$1 before=$2 after=$3
	[[ $before != "$after" ]] || return 0
	local -a services
	mapfile -t services < <(
		comm -12 \
			<(git -C "$repo" diff --name-only "$before" "$after" -- "$stack/config/" | cut -d/ -f3 | sort -u) \
			<(compose "$stack" config --services | sort -u)
	)
	((${#services[@]})) || return 0
	log "$stack: config changed, restarting ${services[*]}"
	compose "$stack" restart "${services[@]}"
}

cmd_link() {
	(($#)) || die "name the stacks to link"
	local arg stack project file
	for arg in "$@"; do
		stack=$(stack_name "$arg")
		project=$projects/$stack
		[[ -f $project/project_name ]] || die "$project has no project_name; add the stack in the plugin first"
		for file in compose.yaml .env; do
			if [[ -f $project/$file ]]; then
				mv "$project/$file" "$project/$file.pre-git"
			fi
		done
		printf '%s' "$repo/$stack" >"$project/indirect"
		printf 'folder' >"$project/indirect_mode"
		log "$stack: linked to $repo/$stack"
	done
}

cmd_up() {
	local pull=true
	if [[ ${1:-} == --no-pull ]]; then
		pull=false
		shift
	fi

	exec 9>/tmp/homelab-deploy.lock
	flock --nonblock 9 || die "another deploy is running"

	[[ -r $op_token_file ]] || die "can't read the 1Password token at $op_token_file"
	OP_SERVICE_ACCOUNT_TOKEN=$(<"$op_token_file")
	export OP_SERVICE_ACCOUNT_TOKEN

	local before after
	before=$(git -C "$repo" rev-parse HEAD)
	if $pull; then
		git -C "$repo" pull --ff-only --quiet
	fi
	after=$(git -C "$repo" rev-parse HEAD)
	if [[ $before != "$after" ]]; then
		log "pulled ${before:0:7}..${after:0:7}"
	fi

	local -a stacks=()
	local arg stack compose_file
	if (($#)); then
		for arg in "$@"; do
			stack=$(stack_name "$arg")
			is_linked "$stack" || die "$stack isn't linked yet; run: $0 link $stack"
			stacks+=("$stack")
		done
		mapfile -t stacks < <(printf '%s\n' "${stacks[@]}" | sort -u)
	else
		for compose_file in "$repo"/[0-9]_*/compose.yaml; do
			stack=$(basename "$(dirname "$compose_file")")
			if ! is_linked "$stack"; then
				log "$stack: skipped, not linked"
			elif ! is_autostart "$stack"; then
				log "$stack: skipped, autostart is off"
			else
				stacks+=("$stack")
			fi
		done
	fi
	((${#stacks[@]})) || die "no stacks to deploy"

	# Everything must render before anything changes.
	for stack in "${stacks[@]}"; do
		render_env "$stack" || die "$stack: couldn't render .env from 1Password"
		compose "$stack" config --quiet || die "$stack: docker compose config failed"
	done

	local -a failed=()
	for stack in "${stacks[@]}"; do
		log "$stack: up"
		if ! compose "$stack" up --detach --remove-orphans || ! restart_changed "$stack" "$before" "$after"; then
			failed+=("$stack")
		fi
	done
	((${#failed[@]} == 0)) || die "failed: ${failed[*]}"
	log "deployed: ${stacks[*]}"
}

main() {
	[[ -d $projects ]] || die "no plugin project folders at $projects"
	case ${1:-} in
	link)
		shift
		cmd_link "$@"
		;;
	up)
		shift
		cmd_up "$@"
		;;
	*) die "usage: $0 link <stack>... | up [--no-pull] [<stack>...]" ;;
	esac
}

main "$@"
