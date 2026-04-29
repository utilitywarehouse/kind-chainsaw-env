# kind-chainsaw-env

A portable, centralized Docker testing environment for running [Chainsaw](https://kyverno.github.io/chainsaw/)
E2E tests against an ephemeral Kubernetes cluster (using `kind`).

This repository builds a test runner image containing `kind`, `chainsaw`, `kubectl`, and `kustomize`.
It is designed to be completely agnostic, meaning you can use it to test Kyverno
policies, ArgoCD applications, or raw Kubernetes manifests.

## Features
* **Isolated Testing:** Spins up a fresh, ephemeral `kind` cluster for every test run.
* **Lightning Fast Iteration:** Set `REUSE_CLUSTER=true` to skip cluster teardown during local development.
* **Easy Debugging:** Native `make kubectl` support to query the test cluster without installing dependencies on your host machine.
* **Portable:** Driven entirely by a generic `Makefile` that can be dropped into any project.

---

## How to use this in your repository

To use this test runner in another project, copy two files into your target repository: the `Makefile` and your Chainsaw configuration YAML.

### Step 1: Copy and Modify the `Makefile`

modify the **Repository-Specific Configuration** block at the top to match your project's needs:

```makefile
# Tell the runner what prerequisites to install before testing
# (Can be a URL, a local folder with a kustomization.yaml, or left blank)
INSTALL_MANIFESTS ?= https://github.com/kyverno/kyverno/raw/main/config/install-latest-testing.yaml

# Tell the runner which namespace to wait on before starting tests
INSTALL_NAMESPACE ?= kube-system

# Point to your Chainsaw configuration file
CHAINSAW_CONFIG ?= .chainsaw.yaml
```

### Step 2: Copy and Modify the `.chainsaw.yaml` file
Chainsaw requires a configuration file to know how to behave.
```
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Configuration
metadata:
  name: generic-configuration
spec:
  parallel: 1
  fullName: true
  forceTerminationGracePeriod: 5s
  timeouts:
    apply: 30s
    assert: 30s
    cleanup: 30s
    delete: 30s
    error: 30s
    exec: 30s
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
If a test fails, Chainsaw normally deletes the resources. Use SKIP_DELETE=true to freeze them in place, then use make kubectl to inspect the cluster.

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
