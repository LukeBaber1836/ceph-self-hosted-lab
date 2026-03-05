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

## Quick Start

```bash
chmod +x bootstrap.sh lab.sh
./bootstrap.sh
```

This single command sets up the entire lab: starts all containers, initializes OSDs,
creates pools and CephFS, configures the dashboard, enables Prometheus, and loads sample data.

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

The `ceph-client` container is your "application node" — it has `rbd`, `ceph-fuse`,
`awscli`, and `s3cmd` pre-installed and the cluster config pre-mounted.

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

Edit `.env` before running `bootstrap.sh`:

| Variable                  | Default        | Description              |
|---------------------------|----------------|--------------------------|
| `CEPH_IMAGE`              | `quay.io/ceph/daemon:latest` | Ceph image     |
| `CEPH_DASHBOARD_PASSWORD` | `admin`        | Dashboard admin password |
| `RGW_S3_ACCESS_KEY`       | `accesskey123` | S3 access key            |
| `RGW_S3_SECRET_KEY`       | `secretkey123` | S3 secret key            |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| OSDs not joining | Check `docker compose logs ceph-osd-1`; ensure `./var/lib/ceph/osd1/ceph-N/` exists |
| Dashboard not loading | `docker compose exec ceph-mgr ceph mgr module enable dashboard` |
| S3 returns 403 | `docker compose exec ceph-rgw radosgw-admin user info --uid=s3user` |
| Grafana shows no data | Wait ~60s for first scrape; check http://localhost:9090/targets |
| Slow first start | Image pull + Rosetta 2 emulation adds ~2 min on Apple Silicon |


A Docker Compose–based Ceph cluster for self-learning on macOS (including Apple Silicon).  
Provides all three Ceph storage interfaces: **Block (RBD)**, **File (CephFS)**, and **Object (S3/RGW)**.

## Architecture

| Container   | Role                           | Port(s)         |
|-------------|--------------------------------|-----------------|
| `ceph-mon`  | Monitor — cluster brain        | —               |
| `ceph-mgr`  | Manager + Web Dashboard        | **8443** (HTTPS)|
| `ceph-osd-1`| Object Storage Daemon 1        | —               |
| `ceph-osd-2`| Object Storage Daemon 2        | —               |
| `ceph-osd-3`| Object Storage Daemon 3        | —               |
| `ceph-mds`  | Metadata Server (CephFS)       | —               |
| `ceph-rgw`  | RADOS Gateway — S3/Swift API   | **8080** (HTTP) |

> **Apple Silicon note:** `quay.io/ceph/daemon` is amd64-only.  
> `platform: linux/amd64` in `docker-compose.yml` runs it via Rosetta 2 transparently.

## Prerequisites

- Docker Desktop (already installed)
- ~4 GB free disk space for images + OSD data

## Quick Start

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

This single command:
1. Creates all required data directories under `./etc/ceph/` and `./var/lib/ceph/`
2. Pulls the `ceph/daemon` image and starts all 7 containers
3. Waits for the cluster to become healthy (~3–5 minutes on first run)
4. Creates the RBD pool, CephFS filesystem, S3 user, and enables the Dashboard

## Verify the Cluster

```bash
# Overall cluster status
docker compose exec ceph-mon ceph -s

# OSD tree (should show 3 OSDs — up and in)
docker compose exec ceph-mon ceph osd tree

# Watch health in real time
docker compose exec ceph-mon ceph -w
```

## Ceph Dashboard

Open **https://localhost:8443** in your browser.  
Login: `admin` / `admin` (change in `.env` before running `bootstrap.sh`)

> Accept the self-signed certificate warning.

## Testing Each Storage Interface

### Block Storage (RBD)

```bash
# Create a 1 GB image
docker compose exec ceph-mon rbd create --size 1G rbd/my-disk

# List images
docker compose exec ceph-mon rbd ls rbd

# Show image details
docker compose exec ceph-mon rbd info rbd/my-disk

# Resize
docker compose exec ceph-mon rbd resize --size 2G rbd/my-disk

# Delete
docker compose exec ceph-mon rbd rm rbd/my-disk
```

### File Storage (CephFS)

```bash
# Check filesystem status
docker compose exec ceph-mon ceph fs status

# Mount inside the MON container using ceph-fuse
docker compose exec ceph-mon bash -c "
  mkdir -p /mnt/cephfs
  ceph-fuse /mnt/cephfs
  echo 'hello cephfs' > /mnt/cephfs/test.txt
  ls /mnt/cephfs
  fusermount -u /mnt/cephfs
"
```

### Object Storage (S3 via RGW)

**Using AWS CLI** (install with `brew install awscli`):

```bash
# Configure credentials once
aws configure set aws_access_key_id accesskey123
aws configure set aws_secret_access_key secretkey123
aws configure set default.region us-east-1

# Create a bucket
aws --endpoint-url http://localhost:8080 s3 mb s3://my-bucket

# Upload a file
aws --endpoint-url http://localhost:8080 s3 cp README.md s3://my-bucket/

# List bucket contents
aws --endpoint-url http://localhost:8080 s3 ls s3://my-bucket/

# Delete bucket
aws --endpoint-url http://localhost:8080 s3 rb s3://my-bucket --force
```

**Using MinIO Client** (install with `brew install minio/stable/mc`):

```bash
mc alias set ceph http://localhost:8080 accesskey123 secretkey123
mc mb ceph/my-bucket
mc ls ceph/
```

## Stopping and Restarting

```bash
# Stop (all data is preserved in ./etc/ceph/ and ./var/lib/ceph/)
docker compose down

# Restart without re-bootstrapping (config persists)
docker compose up -d
```

## Full Reset (Start Fresh)

```bash
docker compose down
rm -rf etc/ var/
./bootstrap.sh
```

## Configuration

Edit `.env` to customise credentials before running `bootstrap.sh`:

| Variable                | Default        | Description                  |
|-------------------------|----------------|------------------------------|
| `CEPH_IMAGE`            | `quay.io/ceph/daemon:latest` | Ceph image to use |
| `CEPH_DASHBOARD_PASSWORD` | `admin`      | Dashboard admin password     |
| `RGW_S3_ACCESS_KEY`     | `accesskey123` | S3 access key                |
| `RGW_S3_SECRET_KEY`     | `secretkey123` | S3 secret key                |

## Useful Commands

```bash
# Pool list
docker compose exec ceph-mon ceph osd pool ls detail

# OSD usage
docker compose exec ceph-mon ceph osd df

# Monitor status
docker compose exec ceph-mon ceph mon stat

# Manager modules
docker compose exec ceph-mgr ceph mgr module ls

# RGW user info
docker compose exec ceph-rgw radosgw-admin user info --uid=s3user

# View logs
docker compose logs -f ceph-mon
docker compose logs -f ceph-osd-1
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| OSDs stuck in `down` | Wait 2–3 min; run `ceph osd tree` to check IDs |
| Dashboard not loading | Run `docker compose exec ceph-mgr ceph mgr module enable dashboard` |
| S3 returns 403 | Verify credentials with `radosgw-admin user info --uid=s3user` |
| Slow start on first run | Image pull + Rosetta 2 emulation adds ~2 min on Apple Silicon |
| `HEALTH_WARN` after start | Usually resolves in a minute; safe to proceed if OSDs are `up` |
