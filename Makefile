# Ceph Learning Lab — Makefile
# Run any target with: make <target>

MON  = docker compose exec -T ceph-mon ceph
RGW  = docker compose exec -T ceph-rgw
CLIENT = docker compose exec ceph-client

.PHONY: help status watch osd-tree pools health \
        osd-fail-1 osd-fail-2 osd-fail-3 \
        osd-recover-1 osd-recover-2 osd-recover-3 \
        client dashboard grafana up down reset logs

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ── Cluster health ────────────────────────────────────────────────────────────
status: ## Show cluster status (ceph -s)
	$(MON) -s

watch: ## Stream live cluster events (ceph -w)  — Ctrl+C to exit
	docker compose exec ceph-mon ceph -w

health: ## Show cluster health detail
	$(MON) health detail

osd-tree: ## Show OSD hierarchy tree
	$(MON) osd tree

pools: ## List all pools with usage stats
	$(MON) osd pool ls detail

pg-stat: ## Show placement group summary
	$(MON) pg stat

df: ## Show cluster disk usage
	$(MON) df

# ── Fault tolerance exercises ─────────────────────────────────────────────────
osd-fail-1: ## Simulate OSD 1 failure (stop container)
	@echo "Stopping ceph-osd-1 — watch with 'make watch' in another terminal"
	docker compose stop ceph-osd-1

osd-fail-2: ## Simulate OSD 2 failure (stop container)
	@echo "Stopping ceph-osd-2 — watch with 'make watch' in another terminal"
	docker compose stop ceph-osd-2

osd-fail-3: ## Simulate OSD 3 failure (stop container)
	@echo "Stopping ceph-osd-3 — watch with 'make watch' in another terminal"
	docker compose stop ceph-osd-3

osd-recover-1: ## Recover OSD 1 (restart container)
	docker compose start ceph-osd-1

osd-recover-2: ## Recover OSD 2 (restart container)
	docker compose start ceph-osd-2

osd-recover-3: ## Recover OSD 3 (restart container)
	docker compose start ceph-osd-3

# ── Client shell ──────────────────────────────────────────────────────────────
client: ## Open an interactive shell in the client container
	docker compose exec ceph-client bash

# ── UI shortcuts ──────────────────────────────────────────────────────────────
dashboard: ## Open the Ceph Dashboard in your browser
	@echo "Opening https://localhost:8443  (admin / admin)"
	@open https://localhost:8443 2>/dev/null || xdg-open https://localhost:8443 2>/dev/null || echo "Visit https://localhost:8443"

grafana: ## Open Grafana in your browser
	@echo "Opening http://localhost:3000  (admin / admin)"
	@open http://localhost:3000 2>/dev/null || xdg-open http://localhost:3000 2>/dev/null || echo "Visit http://localhost:3000"

prometheus: ## Open Prometheus in your browser
	@open http://localhost:9090 2>/dev/null || echo "Visit http://localhost:9090"

# ── Lifecycle ─────────────────────────────────────────────────────────────────
up: ## Start the cluster (no re-bootstrap)
	docker compose up -d

down: ## Stop the cluster (data is preserved)
	docker compose down

logs: ## Tail logs for all containers
	docker compose logs -f

logs-mon: ## Tail MON logs
	docker compose logs -f ceph-mon

logs-osd: ## Tail all OSD logs
	docker compose logs -f ceph-osd-1 ceph-osd-2 ceph-osd-3

reset: ## Full reset — delete all data and re-bootstrap
	@echo "WARNING: This will delete ALL cluster data. Press Ctrl+C to cancel..."
	@sleep 5
	docker compose down
	rm -rf etc/ var/
	./bootstrap.sh
