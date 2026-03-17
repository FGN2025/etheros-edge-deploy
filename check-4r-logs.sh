#!/usr/bin/env bash
echo "=== Last 80 lines of isp-portal-backend logs ==="
docker logs etheros-isp-portal-backend --tail 80 2>&1
echo ""
echo "=== Container status ==="
docker ps -a --filter name=etheros-isp-portal-backend --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
