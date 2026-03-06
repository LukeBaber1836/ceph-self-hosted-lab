# Ceph Learning Lab for ARM Mac OS

A Docker Compose–based Ceph cluster for self-learning on macOS (including Apple Silicon).  
Provides all three Ceph storage interfaces plus a full monitoring stack and guided lab exercises.

## What's Included

| Container       | Role                           | Port(s)         |
|-----------------|--------------------------------|-----------------|
| `ceph-mon`      | Monitor — cluster brain        | —               |
| `ceph-mgr`      | Manager + Web Dashboard        | **8443** (HTTPS)|
| `ceph-osd-1/2/3`| Object Storage Daemons (×3)    | —               |
| `ceph-mds`      | Metadata Server (CephFS)       | —               |
| `ceph-rgw`      | RADOS Gateway — S3/Swift API   | **8080** (HTTP) |
| `ceph-client`   | Lab client node (rbd, awscli)  | —               |
| `prometheus`    | Metrics collection             | **9090**        |
| `grafana`       | Cluster dashboards             | **3000**        |

> **Apple Silicon note:** `quay.io/ceph/daemon` is amd64-only.  
> `platform: linux/amd64` runs it via Rosetta 2 transparently.

## Prerequisites

- **Docker Desktop** — install from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop) if not already present
- **Docker Compose V2** — bundled with Docker Desktop (verify: `docker compose version`)
- **RAM**: allocate at least **8 GB** to Docker Desktop (Preferences → Resources) — 10 containers run simultaneously
- **Disk**: ~6 GB free (image layers + OSD data)
- macOS on Intel or **Apple Silicon** — both supported

## Quick Start

```bash
# 1. (Optional) copy the env file and adjust credentials/settings
cp .env.example .env

# 2. Run the bootstrap
chmod +x bootstrap.sh lab.sh
./bootstrap.sh
```

This single command sets up the entire lab: starts all containers, initializes OSDs,
creates pools and CephFS, configures the dashboard, enables Prometheus, and loads sample data.

If the cluster is already running (e.g. after a manual `docker compose up -d`) and you only
need to re-apply configuration, run `./bootstrap.sh configure` instead.

## Verify the Cluster

```bash
# Overall cluster status
docker compose exec ceph-mon ceph -s

# OSD tree (should show 3 OSDs — up and in)
docker compose exec ceph-mon ceph osd tree

# Watch health in real time
docker compose exec ceph-mon ceph -w

# Pool list with usage
docker compose exec ceph-mon ceph osd pool ls detail
```

## Access Points

| Service         | URL                          | Credentials     |
|-----------------|------------------------------|-----------------|
| Ceph Dashboard  | https://localhost:8443       | admin / admin   |
| Grafana         | http://localhost:3000        | admin / admin   |
| Prometheus      | http://localhost:9090        | —               |
| S3 (RGW)        | http://localhost:8080        | accesskey123 / secretkey123 |

## Guided Lab Exercises

```bash
./lab.sh          # interactive menu
./lab.sh rbd      # Block storage: create images, benchmark, snapshot
./lab.sh s3       # Object storage: buckets, upload, download
./lab.sh cephfs   # File storage: mount CephFS, read/write files
./lab.sh fault    # Fault tolerance: kill an OSD, watch Ceph self-heal
./lab.sh status   # Live cluster event stream (ceph -w)
```

## Common Commands (via Makefile)

```bash
make help          # list all targets
make status        # ceph -s
make watch         # live event stream
make osd-tree      # OSD hierarchy
make df            # disk usage
make client        # open shell in client container
make osd-fail-1    # simulate OSD 1 failure
make osd-recover-1 # restore OSD 1
make dashboard     # open Dashboard in browser
make grafana       # open Grafana in browser
make reset         # full wipe and re-bootstrap
```

## Using the Client Container

The `ceph-client` container is your "application node" — it has `rbd` and `ceph-fuse`
available, and `awscli`/`s3cmd` are installed by `bootstrap.sh` on first run. The cluster
config is pre-mounted read-only.

```bash
# Open an interactive shell
docker compose exec ceph-client bash

# From inside the client:
rbd ls rbd                                      # list block images
aws --endpoint-url http://ceph-rgw:8080 s3 ls   # list S3 buckets
ceph -s                                         # cluster status
```

## Testing Each Storage Interface

### Block Storage (RBD)
```bash
docker compose exec ceph-mon rbd create --size 1G rbd/my-disk
docker compose exec ceph-client rbd bench --io-type write rbd/my-disk
docker compose exec ceph-mon rbd snap create rbd/my-disk@snap1
```

### File Storage (CephFS)
```bash
docker compose exec ceph-mon ceph fs status
docker compose exec ceph-client bash -c "
  mkdir -p /mnt/cephfs && ceph-fuse /mnt/cephfs -f &
  sleep 2 && echo 'hello' > /mnt/cephfs/test.txt && ls /mnt/cephfs
"
```

### Object Storage (S3 via RGW)
```bash
# From the client container (awscli pre-configured)
docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 mb s3://my-bucket
docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 cp /etc/os-release s3://my-bucket/
docker compose exec ceph-client aws --endpoint-url http://ceph-rgw:8080 s3 ls s3://my-bucket/
```

## Stopping and Restarting

```bash
make down          # stop (data preserved in ./etc/ceph and ./var/lib/ceph)
make up            # restart (no re-bootstrap needed)
make reset         # full wipe + rebuild
```

## Configuration

Copy `.env.example` to `.env` and edit before running `bootstrap.sh`:

```bash
cp .env.example .env
```

| Variable                  | Default                      | Description                                  |
|---------------------------|------------------------------|----------------------------------------------|
| `COMPOSE_PROJECT_NAME`    | `ceph_deployment`            | Docker Compose project name (keeps container/network names stable regardless of clone directory) |
| `CEPH_IMAGE`              | `quay.io/ceph/daemon:latest` | Ceph image                                   |
| `MON_IP`                  | `172.20.0.10`                | Monitor IP — must match `docker-compose.yml` |
| `CEPH_PUBLIC_NETWORK`     | `172.20.0.0/24`              | Ceph public network CIDR                     |
| `CEPH_DASHBOARD_PASSWORD` | `admin`                      | Dashboard admin password                     |
| `RGW_S3_ACCESS_KEY`       | `accesskey123`               | S3 access key                                |
| `RGW_S3_SECRET_KEY`       | `secretkey123`               | S3 secret key                                |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| OSDs not joining | Check `docker compose logs ceph-osd-1`; ensure `./var/lib/ceph/osd1/ceph-N/` exists |
| Dashboard not loading | `docker compose exec ceph-mgr ceph mgr module enable dashboard` |
| S3 returns 403 | `docker compose exec ceph-rgw radosgw-admin user info --uid=s3user` |
| Grafana shows no data | Wait ~60s for first scrape; check http://localhost:9090/targets |
| Slow first start | Image pull + Rosetta 2 emulation adds ~2 min on Apple Silicon |
| `HEALTH_WARN` after start | Usually resolves in a minute; safe to proceed while OSDs are `up` |


