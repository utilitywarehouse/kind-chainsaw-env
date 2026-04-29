# kind-chainsaw-env

A portable, centralized Docker testing environment for running [Chainsaw](https://kyverno.github.io/chainsaw/)
E2E tests against an ephemeral Kubernetes cluster (using `kind`).

This repository builds a test runner image containing `kind`, `chainsaw`, `kubectl`, and `kustomize`.
It is designed to be completely agnostic, meaning you can use it to test Kyverno
policies, ArgoCD applications, or raw Kubernetes manifests.

## Zero Local Dependencies (Docker-out-of-Docker)
You **do not** need to install `kind` or `chainsaw` locally.
This runner uses the **Docker-out-of-Docker (DooD)** architecture. 
The `Makefile` mounts local Docker socket into the test runner.
When the test runner creates a cluster, it communicates directly with your host's
Docker daemon to spin up the `kind` cluster as a sibling container. 

---

## How to use this in your repository

To use this test runner in another project, copy `[Makefile](Makefile)` into your target repository.

modify the **Repository-Specific Configuration** block at the top to match your project's needs:

```makefile
# Tell the runner what prerequisites to install before testing
# (Can be a URL, a local folder with a kustomization.yaml, or left blank)
INSTALL_MANIFESTS ?= https://github.com/kyverno/kyverno/raw/main/config/install-latest-testing.yaml

# Tell the runner which namespace to wait on before starting tests
INSTALL_NAMESPACE ?= kyverno
```

#### Local Development Commands

#### 1. Run all tests in the repository:

```bash
make test-all
```
#### 2. Run tests for a specific directory:

```bash
make test-target TEST_DIR=kyverno/policies/pods
```

#### 3. Fast Iteration (Keep the cluster running):

Use `REUSE_CLUSTER=true` to speed up local development. The cluster will stay alive between runs.

```bash
make test-target TEST_DIR=kyverno/policies/pods REUSE_CLUSTER=true
```

#### 4. Debugging a failed test:
If a test fails, Chainsaw normally deletes the resources. Use `SKIP_DELETE=true`
to freeze them in place, then use make kubectl to inspect the cluster.

```bash
# Run the test and freeze the resources
make test-target TEST_DIR=kyverno/policies/pods REUSE_CLUSTER=true SKIP_DELETE=true


# Inspect the cluster
make kubectl CMD="get pods -A"
make kubectl CMD="get events -n default"
```

#### 5. Clean up:
Whenever you use `REUSE_CLUSTER=true`, the cluster stays running on your machine.
use `make clean` to remove ephemeral `kind` cluster
