#!/usr/bin/env bash
# =============================================================================
# Ceph Learning Cluster — Bootstrap Script
#
# Usage:
#   ./bootstrap.sh            Full setup: dirs → start → init OSDs → configure
#   ./bootstrap.sh dirs       Create data directories only (no Docker)
#   ./bootstrap.sh configure  Configure a cluster that is already running
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load env file if present
set -o allexport
# shellcheck disable=SC1091
[[ -f .env ]] && source .env
set +o allexport

IMAGE="${CEPH_IMAGE:-quay.io/ceph/daemon:latest}"
ACCESS_KEY="${RGW_S3_ACCESS_KEY:-accesskey123}"
SECRET_KEY="${RGW_S3_SECRET_KEY:-secretkey123}"
DASHBOARD_PASSWORD="${CEPH_DASHBOARD_PASSWORD:-admin}"

info()    { echo ""; echo ">>> $*"; }
ok()      { echo "    ✓  $*"; }
warn()    { echo "    ⚠  $*"; }
ceph_exec() { docker compose exec -T ceph-mon ceph "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
create_dirs() {
  info "Creating bind-mount directories..."
  mkdir -p \
    etc/ceph \
    var/lib/ceph/mon \
    var/lib/ceph/mgr \
    var/lib/ceph/mds \
    var/lib/ceph/radosgw \
    var/lib/ceph/bootstrap-osd \
    var/lib/ceph/bootstrap-mds \
    var/lib/ceph/bootstrap-rgw \
    var/lib/ceph/osd1 \
    var/lib/ceph/osd2 \
    var/lib/ceph/osd3
  ok "Directories ready."
}

# ─────────────────────────────────────────────────────────────────────────────
wait_healthy() {
  info "Waiting for cluster to become healthy (allow 3–5 minutes)..."
  local attempts=0 max=60
  until docker compose exec -T ceph-mon ceph health 2>/dev/null | grep -qE "HEALTH_OK|HEALTH_WARN"; do
    (( attempts++ )) || true
    if [[ $attempts -ge $max ]]; then
      echo ""
      echo "ERROR: Cluster did not become healthy within $((max * 10))s."
      echo "       Diagnose with: docker compose logs ceph-mon"
      exit 1
    fi
    printf "\r  [%02d/%d] still waiting..." "$attempts" "$max"
    sleep 10
  done
  echo ""
  docker compose exec -T ceph-mon ceph -s
  ok "Cluster is healthy."
}

# ─────────────────────────────────────────────────────────────────────────────
# Write bootstrap keyring files to bind-mount dirs so OSD/MDS/RGW can auth.
export_bootstrap_keyrings() {
  info "Exporting bootstrap keyrings from monitor..."
  ceph_exec auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
  ceph_exec auth get client.bootstrap-mds -o /var/lib/ceph/bootstrap-mds/ceph.keyring
  ceph_exec auth get client.bootstrap-rgw -o /var/lib/ceph/bootstrap-rgw/ceph.keyring
  ok "Bootstrap keyrings written."
}

# ─────────────────────────────────────────────────────────────────────────────
# Initialize OSD data directories with ceph-osd --mkfs so that
# osd_directory_single can find and start each OSD.
# Ceph 18 (Reef) uses bluestore; --mkfs creates the block files in the dir.
setup_osds() {
  info "Initializing OSD data directories (Ceph 18 bluestore)..."
  for i in 1 2 3; do
    local osd_dir="${SCRIPT_DIR}/var/lib/ceph/osd${i}"

    # Skip if this OSD dir already has a ceph-N subdirectory
    if compgen -G "${osd_dir}/ceph-*" > /dev/null 2>&1; then
      ok "OSD ${i}: already initialized, skipping."
      continue
    fi

    info "Initializing OSD ${i}..."

    # Allocate an OSD ID and UUID from the cluster
    local uuid osd_id
    uuid=$(docker compose exec -T ceph-mon bash -c "uuidgen" | tr -d ' \r\n')
    osd_id=$(ceph_exec osd new "$uuid" | tr -d ' \r\n')
    ok "OSD ${i}: allocated OSD.${osd_id} (UUID: ${uuid})"

    # Run a temporary container to initialize the OSD directory.
    # ceph-osd --mkfs creates the bluestore block file and metadata in ceph-N/.
    # --entrypoint bash overrides the ceph/daemon entrypoint.
    docker run --rm \
      --platform linux/amd64 \
      --network ceph_deployment_ceph-net \
      -v "${osd_dir}:/var/lib/ceph/osd" \
      -v "${SCRIPT_DIR}/etc/ceph:/etc/ceph" \
      --entrypoint bash \
      "${IMAGE}" \
      -c "
        set -e
        mkdir -p /var/lib/ceph/osd/ceph-${osd_id}
        ceph auth get-or-create osd.${osd_id} \
          osd 'allow *' mon 'allow profile osd' \
          -o /var/lib/ceph/osd/ceph-${osd_id}/keyring
        ceph-osd -i ${osd_id} --mkfs --osd-uuid ${uuid}
        echo 'mkfs done'
      " 2>&1 | grep -v '^\s*$' | sed 's/^/    /'

    ok "OSD ${i}: initialized as OSD.${osd_id}."
  done
}

# ─────────────────────────────────────────────────────────────────────────────
start_cluster() {
  info "Starting MON first to generate bootstrap keyrings..."
  docker compose up -d ceph-mon
  wait_healthy
  export_bootstrap_keyrings
  setup_osds
  info "Starting remaining containers..."
  docker compose up -d
  ok "All containers started."
}

# ─────────────────────────────────────────────────────────────────────────────
configure_defaults() {
  info "Applying cluster-wide config..."
  ceph_exec config set global osd_pool_default_size 3
  ceph_exec config set global osd_pool_default_min_size 2
  ceph_exec config set mon mon_allow_pool_delete true
  ok "Config applied."
}

# ─────────────────────────────────────────────────────────────────────────────
setup_rbd() {
  info "Setting up Block Storage (RBD)..."
  docker compose exec -T ceph-mon bash -c "
    ceph osd pool create rbd 32 2>/dev/null || echo '  rbd pool already exists'
    rbd pool init rbd 2>/dev/null || true
  "
  ok "RBD pool ready.  Try: docker compose exec ceph-mon rbd create --size 1G rbd/test-disk"
}

# ─────────────────────────────────────────────────────────────────────────────
setup_cephfs() {
  info "Setting up File Storage (CephFS)..."
  docker compose exec -T ceph-mon bash -c "
    ceph osd pool create cephfs_data 32 2>/dev/null    || echo '  pool already exists'
    ceph osd pool create cephfs_metadata 16 2>/dev/null || echo '  pool already exists'
    ceph fs new cephfs cephfs_metadata cephfs_data 2>/dev/null || echo '  filesystem already exists'
  "
  ok "CephFS ready.  Try: docker compose exec ceph-mon ceph fs status"
}

# ─────────────────────────────────────────────────────────────────────────────
setup_dashboard() {
  info "Enabling Ceph Dashboard..."
  docker compose exec -T ceph-mgr ceph mgr module enable dashboard 2>/dev/null || true
  docker compose exec -T ceph-mgr ceph dashboard create-self-signed-cert 2>/dev/null || true
  docker compose exec -T ceph-mgr ceph config set mgr mgr/dashboard/server_addr 0.0.0.0
  docker compose exec -T ceph-mgr ceph config set mgr mgr/dashboard/server_port 8443

  printf '%s' "${DASHBOARD_PASSWORD}" | \
    docker compose exec -T ceph-mgr ceph dashboard ac-user-set-password admin -i - 2>/dev/null || \
  printf '%s' "${DASHBOARD_PASSWORD}" | \
    docker compose exec -T ceph-mgr ceph dashboard set-login-credentials admin -i - 2>/dev/null || \
  warn "Could not set dashboard password automatically. Set it manually in the UI."

  ok "Dashboard: https://localhost:8443  (admin / ${DASHBOARD_PASSWORD})"
  warn "Accept the self-signed certificate warning in your browser."
}

# ─────────────────────────────────────────────────────────────────────────────
setup_monitoring() {
  info "Enabling Prometheus metrics exporter..."
  docker compose exec -T ceph-mgr ceph mgr module enable prometheus 2>/dev/null || true
  docker compose exec -T ceph-mgr ceph config set mgr mgr/prometheus/server_addr 0.0.0.0
  docker compose exec -T ceph-mgr ceph config set mgr mgr/prometheus/server_port 9283
  ok "Prometheus metrics: http://ceph-mgr:9283/metrics (scraped by Prometheus at :9090)"
  ok "Grafana dashboards: http://localhost:3000  (admin / admin)"
}

# ─────────────────────────────────────────────────────────────────────────────
setup_client() {
  info "Preparing client container (installing awscli + s3cmd)..."
  docker compose exec -T ceph-client bash -c "
    pip3 install --quiet awscli s3cmd 2>/dev/null || \
    pip install --quiet awscli s3cmd 2>/dev/null || true
    aws configure set aws_access_key_id ${ACCESS_KEY}
    aws configure set aws_secret_access_key ${SECRET_KEY}
    aws configure set default.region us-east-1
    aws configure set default.output json
  " 2>/dev/null || warn "awscli install skipped (may already be present or pip unavailable)"
  ok "Client container ready.  Enter with: docker compose exec ceph-client bash"
}

# ─────────────────────────────────────────────────────────────────────────────
load_sample_data() {
  info "Loading sample data so there is something to explore..."

  # Small RBD image with some written bytes
  docker compose exec -T ceph-mon bash -c "
    rbd create --size 256M rbd/sample-disk 2>/dev/null || true
    echo 'sample-disk created'
  "

  # A few files on S3
  docker compose exec -T ceph-client bash -c "
    aws --endpoint-url http://ceph-rgw:8080 s3 mb s3://sample-bucket 2>/dev/null || true
    echo 'Welcome to your Ceph S3 bucket!' | \
      aws --endpoint-url http://ceph-rgw:8080 s3 cp - s3://sample-bucket/welcome.txt 2>/dev/null || true
    echo 'sample-bucket populated'
  " 2>/dev/null || warn "S3 sample data skipped (client may not have awscli yet)"

  ok "Sample data loaded. Explore with: make client  →  rbd ls rbd  /  aws s3 ls s3://sample-bucket"
}

# ─────────────────────────────────────────────────────────────────────────────
setup_rgw() {
  info "Setting up Object Storage — RADOS Gateway S3 user..."
  docker compose exec -T ceph-rgw radosgw-admin user create \
    --uid=s3user \
    --display-name="S3 Learning User" \
    --access-key="${ACCESS_KEY}" \
    --secret="${SECRET_KEY}" 2>/dev/null || \
  warn "S3 user may already exist (that's OK)."
  ok "S3 endpoint:  http://localhost:8080"
  ok "Access key:   ${ACCESS_KEY}"
  ok "Secret key:   ${SECRET_KEY}"
}

# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║            Ceph Learning Lab — Ready!                       ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Ceph Dashboard  https://localhost:8443                     ║"
  echo "║                  login: admin / ${DASHBOARD_PASSWORD}$(printf '%*s' $((22 - ${#DASHBOARD_PASSWORD})) '')║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Grafana         http://localhost:3000  (admin / admin)     ║"
  echo "║  Prometheus      http://localhost:9090                      ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  S3 (RGW)        http://localhost:8080                      ║"
  echo "║                  key: ${ACCESS_KEY} / ${SECRET_KEY}$(printf '%*s' $((14 - ${#ACCESS_KEY} - ${#SECRET_KEY})) '')║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Guided labs     ./lab.sh                                   ║"
  echo "║  Quick commands  make help                                  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
configure_all() {
  wait_healthy
  export_bootstrap_keyrings
  setup_osds
  configure_defaults
  setup_rbd
  setup_cephfs
  setup_dashboard
  setup_monitoring
  setup_rgw
  setup_client
  load_sample_data
  print_summary
}

# ─────────────────────────────────────────────────────────────────────────────
main() {
  case "${1:-full}" in
    dirs)
      create_dirs
      ;;
    configure)
      configure_all
      ;;
    full|*)
      echo "╔══════════════════════════════════════════════════════════════╗"
      echo "║       Ceph Learning Cluster — Bootstrap Starting            ║"
      echo "╚══════════════════════════════════════════════════════════════╝"
      create_dirs
      start_cluster   # starts MON → wait healthy → export keyrings → init OSDs → start rest
      configure_defaults
      setup_rbd
      setup_cephfs
      setup_dashboard
      setup_monitoring
      setup_rgw
      setup_client
      load_sample_data
      print_summary
      ;;
  esac
}

main "$@"
