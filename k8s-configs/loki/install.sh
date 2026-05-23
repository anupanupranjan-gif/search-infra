#!/bin/bash
# Install Loki + Promtail for SearchX
# Run this once after cluster setup

echo "Setting inotify limits for Promtail..."
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=524288

echo "Adding Grafana Helm repo..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "Installing loki-stack..."
helm install loki-stack grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.enabled=true \
  --set promtail.enabled=true \
  --wait --timeout 5m

echo "Done. Add Loki data source in Grafana:"
echo "  URL: http://loki-stack.monitoring.svc.cluster.local:3100"
echo "  Set as non-default"
