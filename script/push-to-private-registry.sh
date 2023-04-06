#!/bin/bash

# Check if a registry argument was provided
if [ -z "$1" ]; then
  echo "Usage: $0 <container_registry>"
  exit 1
fi

# Set your registry and additional tags
REGISTRY="$1"
GIT_SHA=$(git rev-parse --short HEAD)
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")

# List all ecosystem tags
ECOSYSTEMS=(
  "bundler"
  "cargo"
  "common"
  "composer"
  "docker"
  "elm"
  "git_submodules"
  "github_actions"
  "go_modules"
  "gradle"
  "hex"
  "maven"
  "npm_and_yarn"
  "nuget"
  "pub"
  "python"
  "terraform"
)

for ECOSYSTEM in "${ECOSYSTEMS[@]}"; do
  SOURCE_IMAGE="ghcr.io/dependabot/dependabot-updater-${ECOSYSTEM}"
  TARGET_IMAGE="${REGISTRY}/dependabot-updater-${ECOSYSTEM}"

  # Tag the images with the new registry and additional tags
  docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}:latest"
  docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}:${GIT_SHA}"
  docker tag "${SOURCE_IMAGE}" "${TARGET_IMAGE}:${TIMESTAMP}"

  # Push the images to the new registry
  docker push "${TARGET_IMAGE}:latest"
  docker push "${TARGET_IMAGE}:${GIT_SHA}"
  docker push "${TARGET_IMAGE}:${TIMESTAMP}"
done
