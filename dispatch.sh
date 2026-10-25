#!/usr/bin/env bash
# Amp self-hosted orb dispatch program — Docker backend.
#
# Amp's orb provider runs this once per lifecycle job and passes the job in
# environment variables. See https://ampcode.com/docs/orbs/self-hosted
#
#   spawn   boot or resume the container for one orb and start `amp orb bootstrap`
#   pause   stop the container, keeping its disk; save a snapshot when asked
#   delete  remove the container and its disk
#
# Every operation is safe to repeat and finishes well within the five-minute budget.
#
# The image boots systemd as PID 1 (`/sbin/init`), which is what lets Amp manage
# long-lived services inside the orb. This works without a privileged container
# because the runtime is sysbox-runc: the container gets its own user namespace,
# so PID 1 is namespaced root, not host root. `--init` is deliberately absent,
# since systemd itself is the init process.
#
# `docker exec` runs `amp orb bootstrap` as `user` explicitly: the container is
# created with `--user root` for systemd, and the dispatch contract wants
# bootstrap running as the image's default user instead.
#
# Docker keeps the container's files but not its memory, so a waking orb runs
# `.agents/resume` instead of `.agents/setup`, and processes started in the orb
# stop when it pauses.
set -euo pipefail

log() {
	printf '%s orb=%s op=%s %s\n' "$(date -Is)" "${ORB_ID:-?}" "${ORB_OPERATION:-?}" "$*"
}

: "${ORB_OPERATION:?ORB_OPERATION is required}"
: "${ORB_ID:?ORB_ID is required}"

# Container for each orb exists  <->  orb exists on this host.
exists() { docker container inspect "$ORB_ID" >/dev/null 2>&1; }

case "$ORB_OPERATION" in
spawn)
	: "${ORB_TOKEN:?ORB_TOKEN is required for spawn}"
	image="${ORB_IMAGE:?ORB_IMAGE is required}"

	# Boot from the project snapshot when Amp prepared one for this orb.
	if [ -n "${ORB_SNAPSHOT_ID-}" ] && docker image inspect "$ORB_SNAPSHOT_ID" >/dev/null 2>&1; then
		image="$ORB_SNAPSHOT_ID"
	fi

	if exists; then
		log "resuming existing container"
		docker start "$ORB_ID" >/dev/null
	else
		log "creating container from $image"
		# systemd is PID 1, so no --init. STOPSIGNAL lets `docker stop` hand
		# systemd a clean power-off instead of killing it after the timeout.
		docker run --user root --stop-signal SIGRTMIN+3 \
			--platform linux/amd64 --shm-size=1g \
			--name "$ORB_ID" -d "$image" /sbin/init >/dev/null
	fi

	# A bare --env NAME copies the value from this provider's environment.
	# `amp orb bootstrap` must run detached, as the image's default user.
	docker exec -d --user user --env ORB_TOKEN ${AMP_URL:+--env AMP_URL} "$ORB_ID" amp orb bootstrap
	;;

pause)
	if exists; then
		log "stopping container"
		docker stop "$ORB_ID" >/dev/null

		if [ -n "${ORB_SNAPSHOT_ID-}" ]; then
			log "saving snapshot $ORB_SNAPSHOT_ID"
			docker commit "$ORB_ID" "$ORB_SNAPSHOT_ID" >/dev/null
		fi
	fi
	;;

delete)
	if exists; then
		log "removing container"
		docker rm -f "$ORB_ID" >/dev/null
	fi
	;;

*)
	log "unknown operation"
	exit 1
	;;
esac
