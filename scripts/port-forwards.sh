#!/usr/bin/env bash
# Background port-forwards to the dev UIs (screenshot day). Each forward reconnects automatically
# if its pod restarts. Binds to 127.0.0.1 only.
#
#   scripts/port-forwards.sh start    # start all forwards in the background
#   scripts/port-forwards.sh status   # show which are running
#   scripts/port-forwards.sh stop     # stop all of them
#
# | Local                  | Target                                  |
# |------------------------|-----------------------------------------|
# | https://localhost:8443 | ArgoCD          argocd/argocd-server:443 |
# | http://localhost:8761  | Eureka          petclinic-dev/discovery-server:8761 |
# | http://localhost:9090  | Spring Boot Admin petclinic-dev/admin-server:9090 |
# | http://localhost:9091  | Prometheus      monitoring/kps-prometheus:9090 |
# | http://localhost:3000  | Grafana         monitoring/grafana:80   |
# | http://localhost:9411  | Zipkin          tracing/zipkin:9411     |
#
# Passwords are never printed by this script; it shows the commands to fetch them yourself.
set -euo pipefail

CONTEXT="${CONTEXT:-petclinic-dev}"   # kube context alias created by install-addons.sh
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/petclinic-port-forwards"

# name|namespace|service|local port|remote port|url
FORWARDS=(
  "argocd|argocd|argocd-server|8443|443|https://localhost:8443"
  "eureka|petclinic-dev|discovery-server|8761|8761|http://localhost:8761"
  "spring-boot-admin|petclinic-dev|admin-server|9090|9090|http://localhost:9090"
  "prometheus|monitoring|kps-prometheus|9091|9090|http://localhost:9091"
  "grafana|monitoring|grafana|3000|80|http://localhost:3000"
  "zipkin|tracing|zipkin|9411|9411|http://localhost:9411"
)

is_running() { [[ -f "$STATE_DIR/$1.pid" ]] && kill -0 "$(cat "$STATE_DIR/$1.pid")" 2>/dev/null; }

start() {
  command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
  command -v setsid >/dev/null || { echo "setsid not found (util-linux)" >&2; exit 1; }
  kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1 \
    || { echo "kube context '$CONTEXT' not found - run scripts/install-addons.sh first" >&2; exit 1; }
  mkdir -p "$STATE_DIR"
  local entry name ns svc lport rport url
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r name ns svc lport rport url <<<"$entry"
    if is_running "$name"; then
      printf '  %-18s already running  %s\n' "$name" "$url"; continue
    fi
    if ! kubectl --context "$CONTEXT" -n "$ns" get svc "$svc" >/dev/null 2>&1; then
      printf '  %-18s SKIPPED (svc %s/%s not found)\n' "$name" "$ns" "$svc"; continue
    fi
    # New session => own process group, so stop can kill the loop and kubectl together.
    setsid bash -c "while true; do
        kubectl --context '$CONTEXT' -n '$ns' port-forward --address 127.0.0.1 'svc/$svc' '$lport:$rport'
        sleep 2
      done" >"$STATE_DIR/$name.log" 2>&1 < /dev/null &
    echo $! >"$STATE_DIR/$name.pid"
    printf '  %-18s started          %s\n' "$name" "$url"
  done
  cat <<EOF

Logins (the commands copy the password to the Windows clipboard via clip.exe; nothing is echoed):
  ArgoCD   user: admin
    kubectl --context $CONTEXT -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | clip.exe
  Grafana  user: admin
    kubectl --context $CONTEXT -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d | clip.exe
  (Not on WSL? replace "| clip.exe" with "| xclip -selection clipboard" or "| pbcopy".)

ArgoCD uses a self-signed certificate: accept the browser warning for https://localhost:8443.
Logs: $STATE_DIR/*.log   Stop: scripts/port-forwards.sh stop
EOF
}

stop() {
  local entry name pid
  for entry in "${FORWARDS[@]}"; do
    name="${entry%%|*}"
    if is_running "$name"; then
      pid="$(cat "$STATE_DIR/$name.pid")"
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      printf '  %-18s stopped\n' "$name"
    fi
    rm -f "$STATE_DIR/$name.pid"
  done
}

status() {
  local entry name ns svc lport rport url
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r name ns svc lport rport url <<<"$entry"
    if is_running "$name"; then
      printf '  %-18s running  %s\n' "$name" "$url"
    else
      printf '  %-18s stopped\n' "$name"
    fi
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  restart) stop; start ;;
  *) echo "usage: $0 {start|stop|status|restart}" >&2; exit 1 ;;
esac
