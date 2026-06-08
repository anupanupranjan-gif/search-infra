#!/bin/bash
# Install PostgreSQL for NexaRank
# Run this once to set up PostgreSQL on a fresh Kind cluster

helm install nexarank-postgres bitnami/postgresql \
  --namespace default \
  --set auth.username=nexarank \
  --set auth.password=nexarank2026 \
  --set auth.database=nexarank \
  --set primary.persistence.size=2Gi \
  --set primary.resources.requests.memory=256Mi \
  --set primary.resources.requests.cpu=100m \
  --set primary.resources.limits.memory=512Mi \
  --set primary.resources.limits.cpu=500m \
  --set volumePermissions.enabled=true
