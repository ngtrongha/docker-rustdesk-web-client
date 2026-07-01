#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[rustdesk-web] %s\n' "$*"
}

fail() {
  printf '[rustdesk-web] ERROR: %s\n' "$*" >&2
  exit 1
}

container_is_ready() {
  local name="$1"
  local running health
  running="$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)"
  [[ "$running" == "true" && ( "$health" == "none" || "$health" == "healthy" ) ]]
}

wait_for_container() {
  local name="$1" timeout_seconds="$2" deadline
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if container_is_ready "$name"; then
      return 0
    fi
    sleep 2
  done
  docker logs --tail 80 "$name" >&2 2>/dev/null || true
  return 1
}

wait_for_web() {
  local bind_ip="$1" bind_port="$2" timeout_seconds="$3" deadline status
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' rustdesk-web-client 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --max-time 5 "http://${bind_ip}:${bind_port}/healthz" >/dev/null && return 0
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 5 "http://${bind_ip}:${bind_port}/healthz" >/dev/null && return 0
      else
        docker exec rustdesk-web-client wget -qO- http://127.0.0.1/healthz >/dev/null && return 0
      fi
    fi
    sleep 2
  done
  docker logs --tail 100 rustdesk-web-client >&2 2>/dev/null || true
  return 1
}

shared_rustdesk_network() {
  local network members
  for network in $(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' rustdesk-hbbs); do
    members="$(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' "$network" 2>/dev/null || true)"
    if grep -qw rustdesk-hbbs <<<"$members" \
      && grep -qw rustdesk-hbbr <<<"$members" \
      && grep -qw rustdesk-api <<<"$members"; then
      printf '%s\n' "$network"
      return 0
    fi
  done
  return 1
}

restore_web() {
  local remote_path="$1" previous_image="$2"
  log "Rolling back only rustdesk-web"

  if [[ -f "$remote_path/.env.web.rollback" && -f "$remote_path/docker-compose.web.yml.rollback" ]]; then
    cp -f "$remote_path/.env.web.rollback" "$remote_path/.env.web"
    cp -f "$remote_path/docker-compose.web.yml.rollback" "$remote_path/docker-compose.web.yml"
    docker compose -p rustdesk-web \
      --env-file "$remote_path/.env.web" \
      -f "$remote_path/docker-compose.web.yml" \
      up -d --no-deps rustdesk-web || true
  elif [[ -n "$previous_image" ]]; then
    docker container rm --force rustdesk-web-client >/dev/null 2>&1 || true
    docker run -d --name rustdesk-web-client --restart unless-stopped "$previous_image" >/dev/null || true
  else
    docker container rm --force rustdesk-web-client >/dev/null 2>&1 || true
    rm -f "$remote_path/.env.web" "$remote_path/docker-compose.web.yml"
  fi
}

rollback_hbbs() {
  local root_path="$1" timeout_seconds="$2"
  local backup="$root_path/docker-compose.yml.pre-web-init"

  [[ -f "$backup" ]] || fail "No hbbs Compose backup exists at $backup"
  log "Rolling back the hbbs Compose change"
  cp -f "$backup" "$root_path/docker-compose.yml.next-rollback"
  mv -f "$root_path/docker-compose.yml.next-rollback" "$root_path/docker-compose.yml"
  (
    cd "$root_path"
    docker compose -f docker-compose.yml up -d --no-deps hbbs
  )
  wait_for_container rustdesk-hbbs "$timeout_seconds" || fail "hbbs did not recover after rollback"
  rm -f "$root_path/.hbbs-web-init-pending"
  log "hbbs rollback completed"
}

initialize_hbbs() {
  local root_path="$1" uploaded_compose="$2" timeout_seconds="$3"
  local current_compose="$root_path/docker-compose.yml"
  local backup="$root_path/docker-compose.yml.pre-web-init"

  [[ -f "$current_compose" ]] || fail "Missing current Compose: $current_compose"
  [[ -f "$uploaded_compose" ]] || fail "Missing uploaded initialization Compose"
  if [[ -f "$backup" ]] && grep -Eq 'command:[[:space:]]*hbbs -k _' "$current_compose"; then
    fail "hbbs has already been initialized; deploy again without -Initialize"
  fi
  grep -Eq 'command:[[:space:]]*hbbs -k _' "$uploaded_compose" \
    || fail "Initialization Compose does not contain the pinned hbbs -k _ command"

  (
    cd "$root_path"
    docker compose -f "$uploaded_compose" config --quiet
  )

  cp -f "$current_compose" "$backup"
  cp -f "$uploaded_compose" "$root_path/docker-compose.yml.next"
  mv -f "$root_path/docker-compose.yml.next" "$current_compose"
  touch "$root_path/.hbbs-web-init-pending"

  log "Recreating hbbs only; hbbr, API and other projects are untouched"
  if ! (
    cd "$root_path"
    docker compose -f docker-compose.yml up -d --no-deps hbbs
  ); then
    rollback_hbbs "$root_path" "$timeout_seconds"
    return 1
  fi

  if ! wait_for_container rustdesk-hbbs "$timeout_seconds"; then
    rollback_hbbs "$root_path" "$timeout_seconds"
    return 1
  fi

  sleep 10
  if ! container_is_ready rustdesk-hbbs; then
    rollback_hbbs "$root_path" "$timeout_seconds"
    return 1
  fi

  log "hbbs is stable; manual LAN client registration confirmation is still required"
}

deploy_web() {
  local remote_path="$1" root_path="$2" image="$3" public_host="$4"
  local api_server="$5" bind_ip="$6" bind_port="$7" timeout_seconds="$8" initialize="$9"
  local incoming="$remote_path/.incoming"
  local uploaded_compose="$incoming/docker-compose.web.yml"
  local image_tar="$incoming/rustdesk-web-image.tar"
  local uploaded_root_compose="$incoming/docker-compose.root.yml"
  local public_key network previous_image=""

  command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
  docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

  if [[ "$initialize" == "true" \
    && -f "$root_path/docker-compose.yml.pre-web-init" \
    && -f "$root_path/docker-compose.yml" ]] \
    && grep -Eq 'command:[[:space:]]*hbbs -k _' "$root_path/docker-compose.yml"; then
    fail "hbbs has already been initialized; deploy again without -Initialize"
  fi

  for container in rustdesk-hbbs rustdesk-hbbr rustdesk-api; do
    container_is_ready "$container" || fail "$container is not running/healthy; deployment was not started"
  done

  network="$(shared_rustdesk_network)" || fail "No shared Docker network found for hbbs, hbbr and API"
  [[ -f "$root_path/data/id_ed25519.pub" ]] || fail "RustDesk public key was not found"
  public_key="$(tr -d '\r\n' < "$root_path/data/id_ed25519.pub")"
  [[ "$public_key" =~ ^[A-Za-z0-9+/=_-]+$ ]] || fail "RustDesk public key has an unexpected format"
  [[ -f "$uploaded_compose" && -f "$image_tar" ]] || fail "Deployment package is incomplete"

  mkdir -p "$remote_path"
  umask 077
  {
    printf 'RUSTDESK_WEB_IMAGE=%s\n' "$image"
    printf 'RUSTDESK_DOCKER_NETWORK=%s\n' "$network"
    printf 'PUBLIC_HOST=%s\n' "$public_host"
    printf 'API_SERVER=%s\n' "$api_server"
    printf 'RENDEZVOUS_SERVER=%s\n' "$bind_ip"
    printf 'RELAY_SERVER=%s\n' "$bind_ip"
    printf 'PRIVATE_BIND_IP=%s\n' "$bind_ip"
    printf 'PRIVATE_BIND_PORT=%s\n' "$bind_port"
    printf 'RUSTDESK_PUBLIC_KEY=%s\n' "$public_key"
  } > "$remote_path/.env.web.next"
  cp -f "$uploaded_compose" "$remote_path/docker-compose.web.yml.next"

  docker compose -p rustdesk-web \
    --env-file "$remote_path/.env.web.next" \
    -f "$remote_path/docker-compose.web.yml.next" \
    config --quiet

  if docker container inspect rustdesk-web-client >/dev/null 2>&1; then
    if [[ ! -f "$remote_path/.env.web" || ! -f "$remote_path/docker-compose.web.yml" ]]; then
      fail "Existing rustdesk-web-client has no rollback metadata; refusing to replace it"
    fi
    previous_image="$(docker inspect --format '{{.Config.Image}}' rustdesk-web-client)"
  fi
  [[ ! -f "$remote_path/.env.web" ]] || cp -f "$remote_path/.env.web" "$remote_path/.env.web.rollback"
  [[ ! -f "$remote_path/docker-compose.web.yml" ]] \
    || cp -f "$remote_path/docker-compose.web.yml" "$remote_path/docker-compose.web.yml.rollback"

  log "Loading the offline image"
  docker load --input "$image_tar" >/dev/null
  docker image inspect "$image" >/dev/null

  if ! mv -f "$remote_path/.env.web.next" "$remote_path/.env.web"; then
    return 1
  fi
  if ! mv -f "$remote_path/docker-compose.web.yml.next" "$remote_path/docker-compose.web.yml"; then
    restore_web "$remote_path" "$previous_image"
    return 1
  fi

  if ! docker compose -p rustdesk-web \
      --env-file "$remote_path/.env.web" \
      -f "$remote_path/docker-compose.web.yml" \
      up -d --no-deps rustdesk-web; then
    restore_web "$remote_path" "$previous_image"
    return 1
  fi

  if ! wait_for_web "$bind_ip" "$bind_port" "$timeout_seconds"; then
    restore_web "$remote_path" "$previous_image"
    return 1
  fi

  if [[ "$initialize" == "true" ]]; then
    initialize_hbbs "$root_path" "$uploaded_root_compose" "$timeout_seconds"
  fi

  rm -f "$image_tar" "$uploaded_compose" "$uploaded_root_compose"

  while IFS= read -r candidate; do
    [[ -z "$candidate" || "$candidate" == "$image" || "$candidate" == "$previous_image" ]] && continue
    docker image rm "$candidate" >/dev/null 2>&1 || true
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' local-rustdesk-web-client)

  log "Deployment healthy at http://${bind_ip}:${bind_port}"
}

case "${1:-}" in
  deploy)
    [[ "$#" -eq 10 ]] || fail "Invalid deploy arguments"
    deploy_web "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
    ;;
  confirm-initialize)
    [[ "$#" -eq 2 ]] || fail "Invalid confirm-initialize arguments"
    rm -f "$2/.hbbs-web-init-pending"
    log "LAN client registration confirmed; initialization committed"
    ;;
  rollback-initialize)
    [[ "$#" -eq 3 ]] || fail "Invalid rollback-initialize arguments"
    rollback_hbbs "$2" "$3"
    ;;
  *)
    fail "Usage: deploy_remote.sh deploy|confirm-initialize|rollback-initialize ..."
    ;;
esac
