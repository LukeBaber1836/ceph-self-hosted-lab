#!/usr/bin/env bash
# =============================================================================
# Ceph Learning Lab — Guided Exercises
#
# Usage:
#   ./lab.sh           Show menu and pick an exercise
#   ./lab.sh rbd       Block storage (RBD) exercise
#   ./lab.sh s3        Object storage (S3/RGW) exercise
#   ./lab.sh cephfs    File storage (CephFS) exercise
#   ./lab.sh fault     Fault tolerance & recovery exercise
#   ./lab.sh status    Live cluster status watch
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[1;36m'; GREEN='\033[1;32m'
YELLOW='\033[1;33m'; RED='\033[1;31m'; RESET='\033[0m'

header() { echo -e "\n${CYAN}━━━  $*  ━━━${RESET}"; }
step()   { echo -e "\n${BOLD}▶  $*${RESET}"; }
info()   { echo -e "   ${YELLOW}ℹ  $*${RESET}"; }
ok()     { echo -e "   ${GREEN}✓  $*${RESET}"; }
prompt() { echo -e "\n${BOLD}Press [Enter] to continue...${RESET}"; read -r; }
run()    { echo -e "   ${CYAN}\$${RESET} $*"; eval "$*"; }
ceph()   { docker compose exec -T ceph-mon ceph "$@"; }
client() { docker compose exec -T ceph-client "$@"; }

check_running() {
  if ! docker compose ps ceph-mon 2>/dev/null | grep -q "healthy"; then
    echo -e "${RED}ERROR: Ceph cluster is not running. Run ./bootstrap.sh first.${RESET}"
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
lab_rbd() {
  check_running
  header "Lab 1: Block Storage (RBD — RADOS Block Device)"
  echo ""
  echo "  RBD provides raw block devices backed by Ceph."
  echo "  In production: VM disks, Kubernetes PVs, database volumes."
  echo "  In this lab: we'll create, inspect, resize, and snapshot an image."
  prompt

  step "1/6 — Check what pools exist"
  info "Ceph stores block images in pools. The 'rbd' pool was created at bootstrap."
  run "docker compose exec ceph-mon ceph osd pool ls"
  prompt

  step "2/6 — Create a 1 GB RBD image"
  info "An 'image' is like a virtual disk. It's thinly provisioned."
  run "docker compose exec ceph-mon rbd create --size 1G rbd/lab-disk"
  run "docker compose exec ceph-mon rbd ls rbd"
  prompt

  step "3/6 — Inspect the image"
  info "Note: 'provisioned size' vs 'disk usage' — bluestore only stores written data."
  run "docker compose exec ceph-mon rbd info rbd/lab-disk"
  prompt

  step "4/6 — Write data to the image (via the client container)"
  info "In a real VM you'd map this via kernel RBD. Here we use 'rbd bench'."
  run "docker compose exec ceph-client rbd bench --io-type write --io-size 4K --io-threads 4 --io-total 64M rbd/lab-disk"
  run "docker compose exec ceph-mon rbd diff rbd/lab-disk | awk '{ sum += \$2 } END { print \"Written:\", sum/1024/1024, \"MiB\" }'"
  prompt

  step "5/6 — Take a snapshot"
  info "Snapshots are copy-on-write — instant and space-efficient."
  run "docker compose exec ceph-mon rbd snap create rbd/lab-disk@snap1"
  run "docker compose exec ceph-mon rbd snap ls rbd/lab-disk"
  prompt

  step "6/6 — Resize the image"
  run "docker compose exec ceph-mon rbd resize --size 2G rbd/lab-disk"
  run "docker compose exec ceph-mon rbd info rbd/lab-disk | grep size"
  prompt

  ok "Lab 1 complete! Clean up with: docker compose exec ceph-mon rbd snap purge rbd/lab-disk && docker compose exec ceph-mon rbd rm rbd/lab-disk"
}

# ─────────────────────────────────────────────────────────────────────────────
lab_s3() {
  check_running
  header "Lab 2: Object Storage (S3 via RADOS Gateway)"
  echo ""
  echo "  Ceph's RADOS Gateway exposes an S3-compatible HTTP API."
  echo "  In this lab: create buckets, upload objects, list, and explore metadata."
  echo "  Endpoint: http://localhost:8080"
  prompt

  step "1/5 — Configure S3 credentials in the client container"
  info "Using the credentials created by bootstrap.sh"
  run "docker compose exec -T ceph-client bash -c \"
    aws configure set aws_access_key_id accesskey123
    aws configure set aws_secret_access_key secretkey123
    aws configure set default.region us-east-1
    aws configure set default.output json
    echo 'Credentials saved.'
  \""
  prompt

  step "2/5 — Create a bucket and upload files"
  run "docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 mb s3://lab-bucket"
  run "docker compose exec -T ceph-client bash -c \"
    echo 'Hello from Ceph S3!' > /tmp/hello.txt
    echo 'Ceph is a distributed storage system.' > /tmp/readme.txt
    aws --endpoint-url http://ceph-rgw:8080 s3 cp /tmp/hello.txt s3://lab-bucket/
    aws --endpoint-url http://ceph-rgw:8080 s3 cp /tmp/readme.txt s3://lab-bucket/docs/
  \""
  prompt

  step "3/5 — List and retrieve objects"
  run "docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 ls s3://lab-bucket --recursive"
  run "docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 cp s3://lab-bucket/hello.txt -"
  prompt

  step "4/5 — Inspect via radosgw-admin"
  info "radosgw-admin is the admin CLI for the RADOS Gateway."
  run "docker compose exec ceph-rgw radosgw-admin bucket stats --bucket=lab-bucket"
  prompt

  step "5/5 — Create a second S3 user"
  run "docker compose exec ceph-rgw radosgw-admin user create --uid=student --display-name='Lab Student' --access-key=student123 --secret=studentsecret"
  run "docker compose exec ceph-rgw radosgw-admin user list"
  prompt

  ok "Lab 2 complete! Bucket remains for inspection. Clean up: docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 rb s3://lab-bucket --force"
}

# ─────────────────────────────────────────────────────────────────────────────
lab_cephfs() {
  check_running
  header "Lab 3: File Storage (CephFS — Distributed Filesystem)"
  echo ""
  echo "  CephFS is a POSIX-compliant filesystem backed by Ceph."
  echo "  It uses a Metadata Server (MDS) for directory structure"
  echo "  and OSDs for actual file data."
  prompt

  step "1/4 — Check CephFS status"
  run "docker compose exec ceph-mon ceph fs status"
  run "docker compose exec ceph-mon ceph mds stat"
  prompt

  step "2/4 — Mount CephFS using ceph-fuse"
  info "ceph-fuse mounts the filesystem in userspace. Perfect for containers."
  run "docker compose exec -T ceph-client bash -c \"
    mkdir -p /mnt/cephfs
    ceph-fuse /mnt/cephfs --client-mountpoint=/ -f &
    sleep 2
    echo 'Mount successful. Files in /mnt/cephfs:'
    ls /mnt/cephfs
  \""
  prompt

  step "3/4 — Create files and directories"
  run "docker compose exec -T ceph-client bash -c \"
    mkdir -p /mnt/cephfs/projects/alpha /mnt/cephfs/projects/beta
    echo 'Project Alpha data' > /mnt/cephfs/projects/alpha/data.txt
    for i in \$(seq 1 5); do echo \"File \$i\" > /mnt/cephfs/projects/beta/file\${i}.txt; done
    echo 'Files written to CephFS:'
    find /mnt/cephfs -type f
  \""
  prompt

  step "4/4 — Check usage statistics"
  run "docker compose exec ceph-mon ceph df"
  run "docker compose exec ceph-client df -h /mnt/cephfs"
  prompt

  ok "Lab 3 complete! CephFS is still mounted in the client container."
}

# ─────────────────────────────────────────────────────────────────────────────
lab_fault() {
  check_running
  header "Lab 4: Fault Tolerance & Self-Healing"
  echo ""
  echo "  One of Ceph's superpowers is automatic recovery from OSD failures."
  echo "  This lab simulates stopping an OSD and watching Ceph react."
  echo ""
  echo -e "  ${YELLOW}Watch the cluster heal in real-time — open another terminal and run:${RESET}"
  echo "    make watch   (or: docker compose exec ceph-mon ceph -w)"
  prompt

  step "1/4 — Baseline cluster status"
  run "docker compose exec ceph-mon ceph osd tree"
  run "docker compose exec ceph-mon ceph -s"
  prompt

  step "2/4 — Simulate an OSD failure (stop ceph-osd-1)"
  info "In production this could be a disk failure, server crash, or network partition."
  run "docker compose stop ceph-osd-1"
  echo ""
  info "Waiting 10 seconds for Ceph to detect the failure..."
  sleep 10
  run "docker compose exec ceph-mon ceph -s"
  info "Look for: 1 osds down, HEALTH_WARN, and potentially some degraded PGs."
  prompt

  step "3/4 — Watch automatic recovery (takes ~1-2 minutes)"
  info "Ceph marks the OSD 'out' and starts remapping PGs to healthy OSDs."
  run "docker compose exec ceph-mon ceph osd tree"
  run "docker compose exec ceph-mon ceph pg stat"
  prompt

  step "4/4 — Restore the OSD and watch recovery"
  info "In production this would be replacing the failed disk and reprovisioning."
  run "docker compose start ceph-osd-1"
  info "Waiting 15 seconds for OSD to rejoin..."
  sleep 15
  run "docker compose exec ceph-mon ceph osd tree"
  run "docker compose exec ceph-mon ceph -s"
  prompt

  ok "Lab 4 complete! You've seen Ceph detect a failure, rebalance data, and recover — all automatically."
}

# ─────────────────────────────────────────────────────────────────────────────
lab_status() {
  check_running
  header "Live Cluster Status"
  echo -e "  ${YELLOW}Press Ctrl+C to exit${RESET}"
  sleep 1
  docker compose exec ceph-mon ceph -w
}

# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
  echo -e "${CYAN}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║              Ceph Learning Lab — Exercises                  ║"
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  echo "  ║  1. rbd     Block Storage (RBD images, snapshots, bench)    ║"
  echo "  ║  2. s3      Object Storage (S3 buckets, upload, download)   ║"
  echo "  ║  3. cephfs  File Storage  (CephFS mount, files, usage)      ║"
  echo "  ║  4. fault   Fault Tolerance (kill OSD, watch recovery)      ║"
  echo "  ║  5. status  Live cluster health  (ceph -w stream)           ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -n "  Choose [1-5 or name]: "
  read -r choice
  case "$choice" in
    1|rbd)    lab_rbd ;;
    2|s3)     lab_s3 ;;
    3|cephfs) lab_cephfs ;;
    4|fault)  lab_fault ;;
    5|status) lab_status ;;
    *) echo "Unknown choice: $choice"; show_menu ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
case "${1:-menu}" in
  rbd)    lab_rbd ;;
  s3)     lab_s3 ;;
  cephfs) lab_cephfs ;;
  fault)  lab_fault ;;
  status) lab_status ;;
  menu|*) show_menu ;;
esac
