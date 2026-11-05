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

        # Deployment availability does not mean the webhook is serving: the
        # listener starts after the containers are Ready and Kyverno registers
        # its webhook configurations at runtime. A policy applied in that
        # window fails with "connection refused", so warm the admission path
        # up with a throwaway policy and wait until Kyverno reports it ready.
        if kubectl get crd validatingpolicies.policies.kyverno.io >/dev/null 2>&1; then
            echo "Waiting for Kyverno to admit and reconcile a policy..."
            cat <<'CANARY' > /tmp/kyverno-canary.yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: chainsaw-kyverno-canary
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [configmaps]
  validations:
    - expression: "true"
CANARY

            # Controllers register their webhooks before the leader-elected
            # workers start, and on a busy runner that gap has been minutes.
            # Give it five.
            kyverno_ready=false
            for i in $(seq 1 150); do
                kubectl create -f /tmp/kyverno-canary.yaml >/dev/null 2>&1 || true
                canary_status=$(kubectl get validatingpolicy.policies.kyverno.io chainsaw-kyverno-canary -o jsonpath='{.status.conditionStatus.ready}/{.status.generated}' 2>/dev/null || true)
                if [ "${canary_status%%/*}" = "true" ]; then
                    kyverno_ready=true
                    break
                fi
                if [ $((i % 10)) -eq 0 ]; then
                    echo "  still waiting ($((i * 2))s): ready/generated=${canary_status:-<not created>}"
                fi
                sleep 2
            done

            kubectl delete validatingpolicy.policies.kyverno.io chainsaw-kyverno-canary --ignore-not-found >/dev/null 2>&1 || true

            if [ "$kyverno_ready" != "true" ]; then
                echo "Timed out waiting for Kyverno to become ready." >&2
                exit 1
            fi
            sleep 2
            echo "Kyverno is ready."
        fi
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
