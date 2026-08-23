#!/bin/bash
# Install PostgreSQL for NexaRank
# Run this once to set up PostgreSQL on a fresh Kind cluster
#
# auth.password is intentionally NOT set: omitting it makes the Bitnami chart
# generate a random password itself and store it directly in the
# nexarank-postgres-postgresql Secret (keys: password, postgres-password) -
# so no credential is ever typed into this script or any other file.
# nexarank-api reads it via secretKeyRef (see k8s-configs/apps/nexarank-api.yaml).
# To read it after install (never paste it elsewhere):
#   kubectl get secret nexarank-postgres-postgresql -n default -o jsonpath='{.data.password}' | base64 -d

helm install nexarank-postgres bitnami/postgresql \
  --namespace default \
  --set auth.username=nexarank \
  --set auth.database=nexarank \
  --set primary.persistence.size=2Gi \
  --set primary.resources.requests.memory=256Mi \
  --set primary.resources.requests.cpu=100m \
  --set primary.resources.limits.memory=512Mi \
  --set primary.resources.limits.cpu=500m \
  --set volumePermissions.enabled=true
