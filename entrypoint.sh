#!/bin/bash

set -e

TEST_TARGET=${1:-"."}
CLUSTER_NAME="chainsaw-test-cluster"

# The image bakes a default; callers can pin a different Kubernetes version.
KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-}
if [ -z "$KIND_NODE_IMAGE" ]; then
    echo "KIND_NODE_IMAGE is empty. The runner image bakes a default, so only set it to override." >&2
    exit 1
fi

INTERNAL_KUBECONFIG="/tmp/kubeconfig"
export KUBECONFIG="$INTERNAL_KUBECONFIG"

# Handle explicit manual cleanup
if [ "$TEST_TARGET" = "clean" ]; then
    echo "Manually destroying the persistent cluster..."
    kind delete cluster --name "$CLUSTER_NAME"
    exit 0
fi

echo "Setting up test environment..."

# Set up the trap based on the REUSE_CLUSTER flag
if [ "$REUSE_CLUSTER" = "true" ]; then
    trap 'echo "REUSE_CLUSTER is active. Leaving cluster running for next time."' EXIT
else
    trap 'echo "Cleaning up..."; kind delete cluster --name "$CLUSTER_NAME"; echo "Cleanup complete!"' EXIT
fi

echo "kind version: $(kind version)"
echo "Node image: $KIND_NODE_IMAGE"

# Create cluster ONLY if it doesn't already exist
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '$CLUSTER_NAME' already exists! Skipping creation."
    CLUSTER_JUST_CREATED=false
else
    echo "Creating kind cluster: $CLUSTER_NAME..."
    kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE"
    CLUSTER_JUST_CREATED=true
fi

# Generate Kubeconfig
kind get kubeconfig --internal --name "$CLUSTER_NAME" > "$INTERNAL_KUBECONFIG"

# Reused clusters keep whatever version they were created with, so show it
kubectl version || true

# Install given manifests and dependencies ONLY if we just created a fresh cluster
if [ "$CLUSTER_JUST_CREATED" = "true" ]; then
    echo "Waiting for kind nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    if [ -n "$INSTALL_MANIFESTS" ]; then
        echo "Installing prerequisites from: $INSTALL_MANIFESTS"
        
        if [[ "$INSTALL_MANIFESTS" == http* ]]; then
            kubectl create -f "$INSTALL_MANIFESTS"
        elif [ -d "/repo/$INSTALL_MANIFESTS" ] && [ -f "/repo/$INSTALL_MANIFESTS/kustomization.yaml" ]; then
            kustomize build "/repo/$INSTALL_MANIFESTS" | kubectl create --namespace "$INSTALL_NAMESPACE" -f -
        else
            kubectl create --namespace "$INSTALL_NAMESPACE" -f "/repo/$INSTALL_MANIFESTS"
        fi
        
        # Wait for Deployments first: `pods --all` only sees pods that exist
        # right now, so it can return before a controller has created its pod.
        echo "Waiting for all deployments in namespace '$INSTALL_NAMESPACE' to be available..."
        kubectl wait --namespace "$INSTALL_NAMESPACE" --for=condition=available deployment --all --timeout=180s

        echo "Waiting for all pods in namespace '$INSTALL_NAMESPACE' to be ready..."
        kubectl wait --namespace "$INSTALL_NAMESPACE" --for=condition=ready pods --all --timeout=120s
    else
        echo "INSTALL_MANIFESTS is empty. Skipping prerequisite installation."
    fi
fi

CHAINSAW_ARGS=("/repo/$TEST_TARGET")

if [ -n "$CHAINSAW_CONFIG" ] && [ -f "/repo/$CHAINSAW_CONFIG" ]; then
    echo "Using custom Chainsaw config from repo: $CHAINSAW_CONFIG"
    CHAINSAW_ARGS+=("--config" "/repo/$CHAINSAW_CONFIG")
else
    echo "No custom config provided. Using default config."
    CHAINSAW_ARGS+=("--config" "/default-chainsaw.yaml")
fi

if [ "$SKIP_DELETE" = "true" ]; then
    echo "🛑 SKIP_DELETE is active: Chainsaw will leave test resources in the cluster."
    CHAINSAW_ARGS+=("--skip-delete")
fi

echo "Running Chainsaw tests against: $TEST_TARGET"
chainsaw test "${CHAINSAW_ARGS[@]}"
