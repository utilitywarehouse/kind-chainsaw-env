#!/bin/bash

set -e

TEST_TARGET=${1:-"."}
CLUSTER_NAME="chainsaw-test-cluster"

INTERNAL_KUBECONFIG="/tmp/kubeconfig"
export KUBECONFIG="$INTERNAL_KUBECONFIG"

# 1. Handle explicit manual cleanup
if [ "$TEST_TARGET" = "clean" ]; then
    echo "Manually destroying the persistent cluster..."
    kind delete cluster --name "$CLUSTER_NAME"
    exit 0
fi

echo "Setting up test environment..."

# 2. Set up the trap based on the REUSE_CLUSTER flag
if [ "$REUSE_CLUSTER" = "true" ]; then
    trap 'echo "REUSE_CLUSTER is active. Leaving cluster running for next time."' EXIT
else
    trap 'echo "Cleaning up..."; kind delete cluster --name "$CLUSTER_NAME"; echo "Cleanup complete!"' EXIT
fi

# 3. Create cluster ONLY if it doesn't already exist
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster '$CLUSTER_NAME' already exists! Skipping creation."
    CLUSTER_JUST_CREATED=false
else
    echo "Creating kind cluster: $CLUSTER_NAME..."
    kind create cluster --name "$CLUSTER_NAME"
    CLUSTER_JUST_CREATED=true
fi

# Generate Kubeconfig
kind get kubeconfig --internal --name "$CLUSTER_NAME" > "$INTERNAL_KUBECONFIG"

# 5. Install given manifests and dependencies ONLY if we just created a fresh cluster
if [ "$CLUSTER_JUST_CREATED" = "true" ]; then
    echo "Waiting for kind nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    if [ -n "$INSTALL_MANIFESTS" ]; then
        echo "Installing prerequisites from: $INSTALL_MANIFESTS"
        
        if [[ "$INSTALL_MANIFESTS" == http* ]]; then
            kubectl create -f "$INSTALL_MANIFESTS"
        elif [ -d "/repo/$INSTALL_MANIFESTS" ] && [ -f "/repo/$INSTALL_MANIFESTS/kustomization.yaml" ]; then
            kustomize build "/repo/$INSTALL_MANIFESTS" | kubectl apply -f -
        else
            kubectl apply -f "/repo/$INSTALL_MANIFESTS"
        fi
        
        echo "Waiting for all pods in namespace '$INSTALL_NAMESPACE' to be available..."
        kubectl wait --namespace "$INSTALL_NAMESPACE" --for=condition=ready pods --all --timeout=120s
    else
        echo "INSTALL_MANIFESTS is empty. Skipping prerequisite installation."
    fi
fi

CHAINSAW_ARGS=("/repo/$TEST_TARGET")

if [ -n "$CHAINSAW_CONFIG" ] && [ -f "/repo/$CHAINSAW_CONFIG" ]; then
    echo "Using custom Chainsaw config: $CHAINSAW_CONFIG"
    CHAINSAW_ARGS+=("--config" "/repo/$CHAINSAW_CONFIG")
else
    echo "No custom Chainsaw config found or provided. Using defaults."
fi

if [ "$SKIP_DELETE" = "true" ]; then
    echo "🛑 SKIP_DELETE is active: Chainsaw will leave test resources in the cluster."
    CHAINSAW_ARGS+=("--skip-delete")
fi

echo "Running Chainsaw tests against: $TEST_TARGET"
chainsaw test "${CHAINSAW_ARGS[@]}"
