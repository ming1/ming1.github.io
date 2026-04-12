---
title: "OpenShift Architecture: Deep Dive from Platform to Large Model Inference"
category: tech
tags: [openshift, kubernetes, containers, gpu, llm, inference, vllm, kserve, ai, cloud-native]
---

* TOC
{:toc}

> **How to read this article:**
> - **Sections 1-6** cover OpenShift fundamentals (architecture, nodes, operators, networking, security)
> - **Sections 7-8** cover OpenShift AI for Large Model Inference (KServe, vLLM, GPU Operator, autoscaling)
> - **Sections 9-10** walk through a complete deployment example with multi-GPU support
> - If you already know Kubernetes, skip to **Section 5.4 (Operators)** — that's where OpenShift diverges.
> - If you only care about LLM serving, skip to **Section 7**.

## 1. What Is OpenShift? (The 30-Second Version)

**OpenShift** is Red Hat's enterprise Kubernetes platform. Think of it as
**Kubernetes + batteries included**: it takes the raw power of Kubernetes and
wraps it with security, automation, a web console, CI/CD pipelines, and
operator-driven lifecycle management — so teams can go from code to production
without assembling dozens of tools by hand.

**One sentence**: OpenShift = Kubernetes + RHCOS + Operators + Security + DevOps tools,
all tested and shipped together as one product.

```
  What You Get with Vanilla Kubernetes vs. OpenShift
  ───────────────────────────────────────────────────

  Vanilla Kubernetes          OpenShift
  ──────────────────          ─────────
  Container orchestration     Container orchestration
  (you add everything else)   + Immutable OS (RHCOS)
                              + Built-in image registry
                              + OAuth / RBAC out of box
                              + Web console
                              + CI/CD (Pipelines, GitOps)
                              + Operator Hub
                              + Automated cluster upgrades
                              + Security Context Constraints
                              + Integrated monitoring
                              + Service Mesh ready
```

**Key idea**: OpenShift is *opinionated*. It makes choices for you (CRI-O not
Docker, RHCOS not random Linux, Operators not Helm-only) so the platform works
reliably at scale from day one.

---

## 2. Motivation: Why OpenShift?

### 2.1 The Problem

Running containers in production is hard. A typical team faces:

| Challenge | What Goes Wrong |
|-----------|----------------|
| **Security** | Who can deploy what? Are images scanned? Are secrets managed? |
| **Day-2 Operations** | How do you upgrade 500 nodes without downtime? |
| **Multi-tenancy** | How do teams share a cluster safely? |
| **Consistency** | Dev, staging, prod must behave the same |
| **GPU/AI Workloads** | How do you schedule LLMs onto GPU nodes efficiently? |

### 2.2 OpenShift's Answer

OpenShift solves these by providing an **integrated, self-managing platform**:

```
  Developer writes code
       │
       ▼
  ┌──────────────────────────────────────────────┐
  │              OpenShift Platform               │
  │                                               │
  │  Source-to-Image ──► Build ──► Registry        │
  │       │                           │            │
  │       ▼                           ▼            │
  │  Pipeline (CI/CD)          Image Scanning      │
  │       │                           │            │
  │       ▼                           ▼            │
  │  Deploy to Cluster ◄─── Admission Policies     │
  │       │                                        │
  │       ▼                                        │
  │  Monitor + Auto-scale + Auto-heal              │
  └──────────────────────────────────────────────┘
       │
       ▼
  User accesses application via Route
```

---

## 3. Architecture Overview: The Layer Cake

OpenShift is built in layers. Each layer builds on the one below it:

```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    User Applications / AI Models                │
  │              (Pods, Deployments, InferenceServices)              │
  ├─────────────────────────────────────────────────────────────────┤
  │                  OpenShift Platform Services                     │
  │  ┌───────────┐ ┌──────────┐ ┌──────────┐ ┌───────────────────┐ │
  │  │  Routes /  │ │ Registry │ │Pipelines │ │  OperatorHub /    │ │
  │  │  Ingress   │ │ (Quay)   │ │ (Tekton) │ │  OLM              │ │
  │  └───────────┘ └──────────┘ └──────────┘ └───────────────────┘ │
  ├─────────────────────────────────────────────────────────────────┤
  │                      Kubernetes Core                             │
  │  ┌───────────┐ ┌──────────┐ ┌──────────┐ ┌───────────────────┐ │
  │  │   API      │ │  etcd    │ │Scheduler │ │ Controller        │ │
  │  │  Server    │ │          │ │          │ │ Manager           │ │
  │  └───────────┘ └──────────┘ └──────────┘ └───────────────────┘ │
  ├─────────────────────────────────────────────────────────────────┤
  │                   Operators (The Glue)                           │
  │  ┌────────────────┐ ┌────────────────┐ ┌──────────────────────┐ │
  │  │ Cluster Version│ │ MachineConfig  │ │ NVIDIA GPU Operator  │ │
  │  │ Operator (CVO) │ │ Operator (MCO) │ │ + Node Feature Disc. │ │
  │  └────────────────┘ └────────────────┘ └──────────────────────┘ │
  ├─────────────────────────────────────────────────────────────────┤
  │              Node Runtime (per node)                             │
  │  ┌───────────┐ ┌──────────┐ ┌──────────────────────────────┐   │
  │  │  kubelet   │ │  CRI-O   │ │  RHCOS (Immutable Linux OS)  │  │
  │  └───────────┘ └──────────┘ └──────────────────────────────┘   │
  ├─────────────────────────────────────────────────────────────────┤
  │                    Infrastructure                                │
  │       Bare Metal / AWS / Azure / GCP / VMware / OpenStack        │
  └─────────────────────────────────────────────────────────────────┘
```

**Reading the diagram from bottom to top:**

1. **Infrastructure** — physical or cloud machines
2. **RHCOS** — immutable, container-optimized OS on each node
3. **CRI-O + kubelet** — run and manage containers on each node
4. **Operators** — software controllers that automate platform lifecycle (they run as pods on top of Kubernetes, but conceptually *glue* the layers together)
5. **Kubernetes core** — API server, scheduler, etcd, controllers
6. **Platform services** — routes, registry, pipelines, operator catalog
7. **Applications** — your workloads, including AI model serving

> **Note**: Operators are shown between the Node Runtime and Kubernetes Core
> layers in the diagram because they bridge both — they run as Kubernetes pods
> but manage OS-level and infrastructure resources.

---

## 4. Node Types

An OpenShift cluster has different kinds of machines:

```
  ┌────────────────────────────────────────────────────────────────┐
  │                      OpenShift Cluster                         │
  │                                                                │
  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
  │  │ Control Plane │  │ Control Plane │  │   Control Plane      │ │
  │  │   Node #1     │  │   Node #2     │  │     Node #3          │ │
  │  │               │  │               │  │                      │ │
  │  │ • API Server  │  │ • API Server  │  │ • API Server         │ │
  │  │ • etcd        │  │ • etcd        │  │ • etcd               │ │
  │  │ • Scheduler   │  │ • Scheduler   │  │ • Scheduler          │ │
  │  │ • Controllers │  │ • Controllers │  │ • Controllers        │ │
  │  └──────────────┘  └──────────────┘  └──────────────────────┘ │
  │                                                                │
  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
  │  │ Worker Node   │  │ Worker Node   │  │ GPU Worker Node      │ │
  │  │   (CPU)       │  │   (CPU)       │  │   (with NVIDIA GPU)  │ │
  │  │               │  │               │  │                      │ │
  │  │ • kubelet     │  │ • kubelet     │  │ • kubelet            │ │
  │  │ • CRI-O       │  │ • CRI-O       │  │ • CRI-O             │ │
  │  │ • App Pods    │  │ • App Pods    │  │ • GPU Device Plugin  │ │
  │  │               │  │               │  │ • vLLM / AI Pods     │ │
  │  └──────────────┘  └──────────────┘  └──────────────────────┘ │
  │                                                                │
  │  ┌──────────────┐  ┌──────────────┐                            │
  │  │ Infra Node    │  │ Infra Node    │   (Optional)             │
  │  │               │  │               │                          │
  │  │ • Router      │  │ • Monitoring  │                          │
  │  │ • Registry    │  │ • Logging     │                          │
  │  └──────────────┘  └──────────────┘                            │
  └────────────────────────────────────────────────────────────────┘
```

| Node Type | Purpose | Minimum Count |
|-----------|---------|---------------|
| **Control Plane** | Runs API server, etcd, scheduler. The brain. | 3 (for HA) |
| **Worker** | Runs user applications. The muscle. | 2+ |
| **GPU Worker** | Worker with NVIDIA/AMD GPU for AI workloads | 1+ (for AI) |
| **Infra** | Runs platform services (router, monitoring, registry) | Optional |

**Special case — Single Node OpenShift (SNO):** For edge deployments or small
AI inference setups, OpenShift can run on a single machine. One server acts as
both control plane and worker. This is useful for running an LLM at a remote
location (e.g., a factory or retail store) where you can't afford a full
cluster but still want OpenShift's operator-driven management.

---

## 5. Building Blocks: Deep Dive

### 5.1 RHCOS — Red Hat Enterprise Linux CoreOS

**What**: An immutable, container-optimized Linux OS that runs on every node.

**Why immutable?** Traditional servers drift over time — someone installs a
package, changes a config, forgets to document it. RHCOS prevents this:

```
  Traditional Linux Server           RHCOS Node
  ─────────────────────              ──────────
  apt install something              Managed by MCO
  edit /etc/some.conf                Config via Ignition
  ssh in to debug                    OS updated as container image
  "works on my machine"             Every node identical

  State: MUTABLE (drifts)           State: IMMUTABLE (consistent)
```

**Key technical points:**
- **Ignition**: First-boot provisioning system. The node boots, reads an
  Ignition config (JSON), sets up disk, network, users — then starts.
- **ostree**: The filesystem is managed by ostree (like git for your OS).
  Updates are atomic — the node reboots into a new image, or rolls back.
- **MachineConfig Operator (MCO)**: When you need to change OS settings
  cluster-wide, you create a `MachineConfig` resource. The MCO rolls it out
  node by node, draining pods first.

```
  How RHCOS Updates Work:
  ───────────────────────

  MCO detects new MachineConfig
       │
       ▼
  Cordon node (no new pods)
       │
       ▼
  Drain running pods
       │
       ▼
  Apply new OS image via ostree
       │
       ▼
  Reboot into new image
       │
       ▼
  Uncordon node (pods return)
       │
       ▼
  Move to next node
```

### 5.2 CRI-O — Container Runtime

**What**: The container runtime that actually runs containers on each node.

**Why not Docker?** Docker includes many features (build, swarm, CLI) that
Kubernetes doesn't need. CRI-O was built *specifically* for Kubernetes —
it does one job (run containers for kubelet) and does it with minimal overhead:

```
  Docker (the old way)              CRI-O (the Kubernetes-native way)
  ────────────────────              ───────────────────────────────────
  dockerd daemon                    No monolithic daemon
  Docker CLI + API                  Only Kubernetes CRI interface
  Docker Swarm built-in             Kubernetes-only, focused
  Image build + run + network       Only run containers
  Large attack surface              Minimal attack surface
```

**Interface**: CRI-O implements the **Container Runtime Interface (CRI)** — a
standard gRPC API that kubelet uses to:

```
  kubelet ──(CRI gRPC)──► CRI-O ──► runc ──► Container
     │                       │
     │  "Start pod X"        │  "Create cgroup, namespace,
     │  "Pull image Y"       │   mount rootfs, exec process"
     │  "Stop container Z"   │
```

### 5.3 Kubernetes Core Components

These are the "brain" running on control plane nodes:

```
  ┌──────────────────────────────────────────────────────────┐
  │                   Control Plane                           │
  │                                                           │
  │  ┌─────────────────┐     ┌──────────────────────┐        │
  │  │   kube-apiserver │◄───►│       etcd            │       │
  │  │                  │     │  (key-value store)    │       │
  │  │  • REST API      │     │  • cluster state      │       │
  │  │  • AuthN/AuthZ   │     │  • desired configs    │       │
  │  │  • Admission     │     │  • 3 replicas (HA)    │       │
  │  └────────┬─────────┘     └──────────────────────┘       │
  │           │                                               │
  │     ┌─────┴──────────────────────┐                        │
  │     │                            │                        │
  │     ▼                            ▼                        │
  │  ┌──────────────────┐  ┌──────────────────────┐          │
  │  │  kube-scheduler   │  │kube-controller-mgr   │         │
  │  │                   │  │                      │          │
  │  │  "Which node      │  │  "Is desired state   │          │
  │  │   should this     │  │   == actual state?   │          │
  │  │   pod run on?"    │  │   If not, fix it."   │          │
  │  └──────────────────┘  └──────────────────────┘          │
  └──────────────────────────────────────────────────────────┘
```

| Component | Job | Key Detail |
|-----------|-----|------------|
| **kube-apiserver** | Front door for all requests | Every `oc` command, every operator, hits this API |
| **etcd** | Stores all cluster state | Consensus via Raft; 3 replicas minimum |
| **kube-scheduler** | Assigns pods to nodes | Considers CPU, memory, GPU, affinity, taints |
| **kube-controller-manager** | Reconciliation loops | "Desired state → Actual state" for deployments, replicasets, etc. |

### 5.4 Operators — The Heart of OpenShift

**What**: An Operator is a custom controller that watches a Custom Resource (CR)
and takes action to make the real world match the desired state.

Think of it like a **robot system administrator** that never sleeps:

```
  Traditional Admin                    Operator
  ────────────────                    ─────────
  "Check if DB is running"           Watch CR for desired state
  "If crashed, restart it"           Compare desired vs actual
  "Run backup at 2 AM"               Reconcile (fix differences)
  "Upgrade to v2.1"                  Repeat forever
  (manual, error-prone)              (automated, reliable)
```

**How an Operator works:**

```
  ┌──────────────┐     ┌─────────────────┐     ┌──────────────┐
  │   User        │     │   API Server     │     │   Operator    │
  │               │     │                  │     │   Controller  │
  │  "I want 3    │────►│  Store CR in     │────►│  Watch for    │
  │   GPU nodes   │     │  etcd            │     │  CR changes   │
  │   with vLLM"  │     │                  │     │               │
  └──────────────┘     └─────────────────┘     │  Compare:      │
                                                │  desired=3     │
                                                │  actual=1      │
                                                │               │
                                                │  Action:       │
                                                │  Create 2 more │
                                                │  GPU nodes     │
                                                └──────────────┘
```

**The Reconciliation Loop** — This is the core design pattern behind all
Operators and Kubernetes controllers:

```
              ┌─────────────────────────────────┐
              │         Reconciliation Loop       │
              │                                   │
              │   ┌──────────┐                    │
         ┌───►│   │  WATCH    │  Listen for events │
         │    │   │  (etcd)   │  on Custom Resource│
         │    │   └─────┬────┘                    │
         │    │         │                          │
         │    │         ▼                          │
         │    │   ┌──────────┐                    │
         │    │   │ COMPARE   │  Desired state     │
         │    │   │           │  vs actual state    │
         │    │   └─────┬────┘                    │
         │    │         │                          │
         │    │    Match? ──Yes──► Do nothing       │
         │    │         │                          │
         │    │        No                          │
         │    │         │                          │
         │    │         ▼                          │
         │    │   ┌──────────┐                    │
         │    │   │   ACT     │  Create/update/    │
         │    │   │           │  delete resources   │
         │    │   └─────┬────┘                    │
         │    │         │                          │
         └────┼─────────┘   (loop forever)        │
              └─────────────────────────────────┘
```

This pattern is everywhere in OpenShift. The CVO watches for new release
images. The MCO watches for MachineConfig changes. The GPU Operator watches
for nodes with GPUs. KServe watches for InferenceService objects. They all
follow the same Watch → Compare → Act loop.

**Critical OpenShift Operators:**

| Operator | What It Manages |
|----------|----------------|
| **Cluster Version Operator (CVO)** | Upgrades the entire cluster |
| **MachineConfig Operator (MCO)** | OS configuration on all nodes |
| **Ingress Operator** | External traffic routing |
| **NVIDIA GPU Operator** | GPU drivers, device plugin, monitoring |
| **OpenShift AI Operator** | AI/ML platform (KServe, model serving) |
| **Operator Lifecycle Manager (OLM)** | Installs and manages other operators |

### 5.5 Networking

OpenShift networking handles three types of traffic:

```
  ┌──────────────────────────────────────────────────────────────┐
  │                     Traffic Types                             │
  │                                                               │
  │  1. Pod-to-Pod (East-West)                                    │
  │     ┌──────┐  overlay network  ┌──────┐                       │
  │     │Pod A │◄─────────────────►│Pod B │                       │
  │     └──────┘   (OVN-Kubernetes)└──────┘                       │
  │                                                               │
  │  2. External-to-Pod (North-South)                             │
  │     Internet ──► Route ──► Service ──► Pod                    │
  │                                                               │
  │  3. Pod-to-External                                           │
  │     Pod ──► Service ──► Egress ──► External API               │
  └──────────────────────────────────────────────────────────────┘
```

**Routes** are an OpenShift concept (not in vanilla Kubernetes). A Route
exposes a Service to the outside world with TLS termination:

```
  https://myapp.apps.cluster.example.com
       │
       ▼
  ┌──────────────┐     ┌─────────────┐     ┌──────────┐
  │   HAProxy     │────►│   Service    │────►│   Pod     │
  │   Router      │     │  (ClusterIP) │     │  (app)    │
  └──────────────┘     └─────────────┘     └──────────┘
```

### 5.6 Image Registry

OpenShift includes a built-in container image registry:

```
  Developer pushes image
       │
       ▼
  ┌────────────────────────────┐
  │   OpenShift Image Registry  │
  │                              │
  │  • Integrated with RBAC      │
  │  • Image stream triggers     │
  │  • Vulnerability scanning    │
  │  • Only trusted images run   │
  └────────────────────────────┘
       │
       ▼
  ImageStream notifies OpenShift
       │
       ▼
  Automatic rebuild/redeploy
```

**ImageStreams** are another OpenShift-specific concept: they track image tags
and can trigger builds/deployments when a new image is pushed.

### 5.7 Security Model

OpenShift has a layered security model:

```
  ┌──────────────────────────────────────────────────────┐
  │  Layer 1: Authentication (OAuth / LDAP / OIDC)       │
  ├──────────────────────────────────────────────────────┤
  │  Layer 2: RBAC (who can do what in which namespace)  │
  ├──────────────────────────────────────────────────────┤
  │  Layer 3: Security Context Constraints (SCC)         │
  │           (restrict what a container CAN do)          │
  │           • Run as non-root by default                │
  │           • No privileged containers                  │
  │           • No host network access                    │
  ├──────────────────────────────────────────────────────┤
  │  Layer 4: Network Policies (pod-to-pod firewall)     │
  ├──────────────────────────────────────────────────────┤
  │  Layer 5: Image Admission (reject unsigned images)   │
  └──────────────────────────────────────────────────────┘
```

**Key difference from vanilla Kubernetes**: In OpenShift, containers run as
**non-root by default**. Vanilla Kubernetes allows root containers unless you
configure PodSecurityStandards.

**Note for GPU workloads**: The NVIDIA GPU Operator pods require the `privileged`
SCC because they load kernel modules (GPU drivers). This is a controlled
exception — the GPU Operator runs in its own namespace with restricted RBAC,
and your *application* pods (e.g., vLLM) still run as non-root.

---

## 6. Observability Stack

OpenShift ships with integrated monitoring — you don't install Prometheus
separately; it's there from day one.

```
  ┌──────────────────────────────────────────────────────────┐
  │                   Observability                           │
  │                                                           │
  │  ┌────────────────┐  ┌────────────┐  ┌────────────────┐  │
  │  │   Prometheus    │  │  Alerting   │  │   Grafana      │  │
  │  │                 │  │  Manager    │  │   Dashboards   │  │
  │  │  Scrapes metrics│  │             │  │                │  │
  │  │  every 30s from │  │  Routes     │  │  Visualize     │  │
  │  │  all pods/nodes │  │  alerts to  │  │  cluster and   │  │
  │  │                 │  │  PagerDuty, │  │  app metrics   │  │
  │  │                 │  │  Slack, etc │  │                │  │
  │  └────────────────┘  └────────────┘  └────────────────┘  │
  │                                                           │
  │  ┌────────────────┐  ┌──────────────────────────────────┐ │
  │  │ Cluster Logging │  │  Distributed Tracing             │ │
  │  │ (Loki / EFK)    │  │  (Jaeger / Tempo)                │ │
  │  └────────────────┘  └──────────────────────────────────┘ │
  └──────────────────────────────────────────────────────────┘
```

**For AI workloads**, the observability stack becomes even more important:
the NVIDIA DCGM Exporter feeds GPU metrics (utilization, memory, temperature,
power) into Prometheus, and vLLM exposes inference-specific metrics (tokens/sec,
queue depth, latency). Both are visible in Grafana dashboards out of the box.
This is what makes SLO-driven autoscaling (Section 8) possible.

---

## 7. OpenShift AI: The AI/ML Platform Layer

OpenShift AI (formerly Red Hat OpenShift Data Science) adds an AI/ML platform
on top of OpenShift. This is where Large Model Inference lives.

OpenShift AI provides **two model serving platforms**:

```
  Single-Model Serving (KServe)       Multi-Model Serving (ModelMesh)
  ─────────────────────────────       ─────────────────────────────────
  One model per pod                   Multiple models share one pod
  Full GPU per model                  Models time-share GPU
  Best for: LLMs, large models       Best for: Many small models
  Used for: vLLM inference            Used for: Traditional ML (sklearn, etc.)
       ▲
       └── This article focuses on single-model serving
```

### 7.1 OpenShift AI Architecture (Single-Model Serving)

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                       OpenShift AI                                │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │                  Model Serving Layer                         │  │
  │  │  ┌──────────┐  ┌───────────┐  ┌──────────────────────────┐  │  │
  │  │  │  KServe   │  │  Knative   │  │  Istio (Service Mesh)   │  │  │
  │  │  │           │  │  Serving   │  │                          │  │  │
  │  │  │ Inference │  │  Auto-     │  │  Traffic routing,        │  │  │
  │  │  │ Service   │  │  scaling   │  │  mTLS, observability     │  │  │
  │  │  │ CRDs      │  │  (0→N)    │  │                          │  │  │
  │  │  └──────────┘  └───────────┘  └──────────────────────────┘  │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │               Serving Runtimes                               │  │
  │  │  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │  │
  │  │  │ vLLM (NVIDIA)  │  │ vLLM (AMD)    │  │ vLLM (Intel    │  │  │
  │  │  │ ServingRuntime │  │ ServingRuntime │  │  Gaudi)        │  │  │
  │  │  └───────────────┘  └───────────────┘  └────────────────┘   │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │                 GPU / Accelerator Layer                      │  │
  │  │  ┌───────────────────┐  ┌─────────────────────────────────┐ │  │
  │  │  │  NVIDIA GPU        │  │  Node Feature Discovery (NFD)   │ │  │
  │  │  │  Operator          │  │                                  │ │  │
  │  │  │                    │  │  Scans hardware ──► Labels nodes │ │  │
  │  │  │  • GPU drivers     │  │  PCI ID 10de = NVIDIA GPU        │ │  │
  │  │  │  • Device plugin   │  │                                  │ │  │
  │  │  │  • DCGM monitoring │  │                                  │ │  │
  │  │  │  • Container toolkit│ │                                  │ │  │
  │  │  └───────────────────┘  └─────────────────────────────────┘ │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │               Model Storage                                  │  │
  │  │  ┌──────────┐  ┌──────────┐  ┌──────────────────────────┐   │  │
  │  │  │  S3       │  │  PVC      │  │  OCI (ModelCar)          │  │  │
  │  │  │  Bucket   │  │  Volume   │  │  Model as Container      │  │  │
  │  │  └──────────┘  └──────────┘  └──────────────────────────┘   │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  │                                                                   │
  │  ┌─────────────────────────────────────────────────────────────┐  │
  │  │               Model Governance                               │  │
  │  │  ┌──────────────┐  ┌──────────────────┐                      │  │
  │  │  │  TrustyAI     │  │  Prometheus +    │                     │  │
  │  │  │  (fairness,   │  │  DCGM metrics    │                     │  │
  │  │  │  explainability│ │  (GPU monitoring) │                     │  │
  │  │  └──────────────┘  └──────────────────┘                      │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  └──────────────────────────────────────────────────────────────────┘
```

### 7.2 Key Components for LLM Inference

#### KServe — Model Serving Orchestrator

KServe is the **brain** that orchestrates model serving. It provides:

```
  What KServe Does:
  ─────────────────

  1. Define WHAT to serve    ──►  InferenceService CR
  2. Define HOW to serve     ──►  ServingRuntime CR
  3. Scale automatically     ──►  Knative or KEDA
  4. Route traffic           ──►  Istio service mesh
  5. Canary deployments      ──►  Traffic splitting
```

KServe supports two modes:

```
  Serverless Mode (Knative)          RawDeployment Mode
  ─────────────────────────          ──────────────────
  Scale to zero when idle            Always running
  Knative + Istio required           Simpler setup
  Best for bursty workloads          Best for steady traffic
  Higher cold-start latency          No cold-start
```

#### vLLM — The Inference Engine

**vLLM** is the actual engine that loads model weights into GPU memory and
generates tokens. It is the default serving runtime in OpenShift AI.

```
  Why vLLM Is Chosen:
  ───────────────────

  ┌──────────────────────────────────────────────────────────┐
  │                        vLLM                               │
  │                                                           │
  │  • PagedAttention        ──►  2-4x better GPU memory      │
  │                               utilization vs naive approach│
  │                                                           │
  │  • Continuous batching   ──►  Don't wait for slowest       │
  │                               request in batch             │
  │                                                           │
  │  • Tensor parallelism    ──►  Split model across           │
  │                               multiple GPUs                │
  │                                                           │
  │  • KV-cache offloading   ──►  Spill to CPU memory          │
  │    (with LMCache)             for longer contexts           │
  │                                                           │
  │  • OpenAI-compatible API ──►  Drop-in replacement           │
  │                               for OpenAI endpoints          │
  └──────────────────────────────────────────────────────────┘
```

**PagedAttention explained simply:**

```
  Traditional Attention Memory         PagedAttention (vLLM)
  ────────────────────────────         ──────────────────────

  Each request gets a fixed            Memory allocated in small
  contiguous block of GPU mem:         pages, like OS virtual memory:

  ┌──────────────────────────┐         ┌────┬────┬────┬────┐
  │  Request 1: 8 GB block   │         │ R1 │ R2 │ R1 │ R3 │  Page 0-3
  │  (mostly wasted space)   │         ├────┼────┼────┼────┤
  ├──────────────────────────┤         │ R2 │ R1 │ R3 │free│  Page 4-7
  │  Request 2: 8 GB block   │         ├────┼────┼────┼────┤
  │  (mostly wasted space)   │         │free│free│free│free│  Page 8-11
  ├──────────────────────────┤         └────┴────┴────┴────┘
  │  Request 3: can't fit!   │
  │  OUT OF MEMORY           │         Request 3: fits! Pages
  └──────────────────────────┘         allocated on demand.

  Waste: ~60-80%                       Waste: ~5%
  Throughput: Low                      Throughput: 2-4x higher
```

**Continuous batching explained simply:**

```
  Static Batching (traditional)       Continuous Batching (vLLM)
  ─────────────────────────────       ─────────────────────────────

  Wait until batch is full, then      Process requests as they arrive.
  process ALL together. Short         When a short request finishes,
  requests wait for long ones.        immediately slot in a new one.

  Time ──────────────────────►        Time ──────────────────────►

  │ Req A: ████████████████│          │ Req A: ████████████████│
  │ Req B: ████░░░░░░░░░░░░│          │ Req B: ████│
  │ Req C: ████████░░░░░░░░│          │        Req D: ██████████│
  │ (wait for batch 2...)  │          │ Req C: ████████│
  │ Req D: ████████████████│          │         Req E: ████████│
  │ Req E: ████████░░░░░░░░│          │ Req F: ██████████████│
                                      │
  ░ = idle GPU (wasted)               No idle time: GPU always busy.
  Batch 1 must all finish             Each request leaves as soon
  before batch 2 starts.              as it's done.

  GPU utilization: ~40-60%            GPU utilization: ~85-95%
```

#### NVIDIA GPU Operator — Hardware Access

The GPU Operator makes GPUs visible to Kubernetes:

```
  Without GPU Operator               With GPU Operator
  ────────────────────               ─────────────────
  Manually install drivers           Auto-install drivers
  Manually configure runtime         Auto-configure toolkit
  No GPU monitoring                  DCGM metrics to Prometheus
  Manual device plugin               Auto device plugin
  "nvidia-smi works on host          "kubectl describe node"
   but not in pods"                   shows: nvidia.com/gpu: 4
```

**Installation chain:**

```
  Step 1: Install NFD Operator
       │
       ▼
  NFD scans nodes, finds PCI ID 10de (NVIDIA)
       │
       ▼
  Labels node: feature.node.kubernetes.io/pci-10de.present=true
       │
       ▼
  Step 2: Install GPU Operator
       │
       ▼
  GPU Operator sees labeled nodes, deploys:
       │
       ├──► NVIDIA driver container (builds/loads kernel module)
       ├──► NVIDIA container toolkit (nvidia-ctk)
       ├──► GPU device plugin (exposes nvidia.com/gpu resource)
       ├──► GPU Feature Discovery (labels GPU model, memory, etc.)
       └──► DCGM Exporter (GPU metrics for Prometheus)
```

#### GPU Sharing Methods

When you don't need a full GPU per workload:

```
  ┌──────────────────────────────────────────────────────────────┐
  │                   GPU Sharing Options                         │
  │                                                               │
  │  ┌────────────────┐  ┌───────────────┐  ┌─────────────────┐  │
  │  │  Time-Slicing   │  │     MIG        │  │   CUDA MPS      │  │
  │  │                 │  │                │  │                  │  │
  │  │ • Round-robin   │  │ • Hardware     │  │ • Software       │  │
  │  │   GPU access    │  │   partitions   │  │   multiprocess   │  │
  │  │ • No memory     │  │ • True memory  │  │ • Shared memory  │  │
  │  │   isolation     │  │   isolation    │  │ • Less overhead  │  │
  │  │ • Simple setup  │  │ • A100/H100+   │  │   than slicing   │  │
  │  │                 │  │   (Ampere+)    │  │                  │  │
  │  │ Good for:       │  │ Good for:      │  │ Good for:        │  │
  │  │ Dev/test,       │  │ Production     │  │ Many small       │  │
  │  │ small models    │  │ multi-tenant   │  │ concurrent       │  │
  │  │                 │  │ isolation      │  │ CUDA tasks       │  │
  │  └────────────────┘  └───────────────┘  └─────────────────┘  │
  └──────────────────────────────────────────────────────────────┘
```

### 7.3 GPU Memory Sizing Guide

```
  Model Size         GPU Memory Needed         Example GPU
  ──────────         ────────────────         ───────────
  1B - 8B params     24 GB                    NVIDIA A10, L4
  8B - 20B params    48 GB                    NVIDIA A40, L40
  20B - 34B params   80 GB                    NVIDIA A100-80GB
  34B - 70B params   160 GB (2x GPUs)         2x A100-80GB
  70B+ params        320 GB+ (4+ GPUs)        4x A100-80GB, H100
```

**Rule of thumb**: In FP16 (half-precision), each billion parameters needs
roughly **2 GB of GPU memory** just for weights. Add 20-50% overhead for
KV-cache and runtime.

### 7.4 Quantization: Trading Precision for Speed

You can shrink a model to fit on fewer GPUs using **quantization** — reducing
the number of bits per weight:

```
  Precision   Bits/Weight   Memory per 1B params   Quality Impact
  ─────────   ───────────   ────────────────────   ──────────────
  FP32        32 bits       4 GB                   Baseline (full)
  FP16/BF16   16 bits       2 GB                   Negligible loss
  INT8 (W8A8) 8 bits        1 GB                   Minimal loss
  INT4 (GPTQ) 4 bits        0.5 GB                 Noticeable on hard tasks

  Example: Llama 3 70B
  ─────────────────────
  FP16:  140 GB  →  needs 2x A100-80GB
  INT8:   70 GB  →  fits on 1x A100-80GB
  INT4:   35 GB  →  fits on 1x A40-48GB
```

vLLM supports quantized models natively — you just point it at a pre-quantized
model (e.g., GPTQ or AWQ format) and add `--quantization gptq` or
`--quantization awq` to the serving runtime args.

---

## 8. Autoscaling for LLM Inference

Traditional autoscaling (CPU %, request count) doesn't work well for LLMs
because GPU utilization and token throughput are what matter.

### 8.1 KEDA vs Knative Autoscaling

**KEDA** (Kubernetes Event-Driven Autoscaling) is an autoscaler that can scale
based on custom metrics — not just CPU/memory. For LLMs, this means scaling
based on actual inference quality metrics from vLLM.

```
  ┌──────────────────────────────────────────────────────────────┐
  │                  Autoscaling Approaches                       │
  │                                                               │
  │  Knative (built-in)              KEDA (recommended for LLMs)  │
  │  ─────────────────              ────────────────────────────   │
  │                                                               │
  │  Scales on:                     Scales on:                    │
  │  • Request concurrency          • Inter-Token Latency (ITL)   │
  │  • Requests per second          • End-to-end response time    │
  │                                 • vLLM queue depth            │
  │                                 • GPU memory pressure         │
  │                                                               │
  │  Problem:                       Advantage:                    │
  │  One long request ≠             Directly measures user-felt   │
  │  one short request.             quality (SLO-driven)          │
  │  Concurrency is a poor                                        │
  │  proxy for LLM load.           Result in benchmarks:          │
  │                                 86.9% success rate vs         │
  │                                 lower for Knative alone       │
  └──────────────────────────────────────────────────────────────┘
```

### 8.2 Autoscaling Flow

```
  User request ──► Istio Gateway ──► KServe InferenceService
                                           │
                                           ▼
                                    ┌──────────────┐
                                    │  vLLM Pod #1  │──── Prometheus
                                    │  (GPU node)   │     metrics
                                    └──────────────┘        │
                                                            ▼
                                                    ┌──────────────┐
                                                    │    KEDA       │
                                                    │  Autoscaler   │
                                                    │               │
                                                    │ "ITL > 200ms" │
                                                    │ "Scale up!"   │
                                                    └──────┬───────┘
                                                           │
                                                           ▼
                                                    ┌──────────────┐
                                                    │  vLLM Pod #2  │
                                                    │  (new GPU node)│
                                                    └──────────────┘
```

---

## 9. End-to-End Example: Deploying Llama 3 on OpenShift AI

Let's walk through a real scenario: deploying **Meta Llama 3 8B** for inference
on OpenShift AI with vLLM.

### 9.1 The Problem We're Solving

A company wants to:
- Host their own LLM (not send data to OpenAI) for **data privacy**
- Serve it as a REST API that's **OpenAI-compatible**
- **Auto-scale** based on demand (scale down at night, up during business hours)
- **Monitor** GPU utilization and response latency

### 9.2 Prerequisites

```
  What You Need:
  ──────────────

  ┌─────────────────────────────────────────────────────────────┐
  │  OpenShift Cluster (4.14+)                                   │
  │    ├── 3x Control Plane nodes (no GPU needed)                │
  │    ├── 2x Worker nodes (for regular apps)                    │
  │    └── 1x GPU Worker node                                    │
  │         └── NVIDIA A100 80GB GPU                             │
  │                                                              │
  │  Installed Operators:                                        │
  │    ├── Node Feature Discovery (NFD)                          │
  │    ├── NVIDIA GPU Operator                                   │
  │    ├── OpenShift Serverless (Knative)                         │
  │    ├── OpenShift Service Mesh (Istio)                         │
  │    └── Red Hat OpenShift AI                                   │
  │                                                              │
  │  Model Storage:                                              │
  │    └── S3 bucket with Llama-3-8B weights (~16 GB in FP16)    │
  └─────────────────────────────────────────────────────────────┘
```

### 9.3 Step-by-Step Deployment

```
  Step 1: Install NFD → Labels GPU nodes
  ───────────────────────────────────────

  $ oc get nodes --show-labels | grep nvidia
  gpu-worker-1   feature.node.kubernetes.io/pci-10de.present=true
                 nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB
                 nvidia.com/gpu.memory=81920
```

```
  Step 2: Install GPU Operator → Makes GPUs schedulable
  ──────────────────────────────────────────────────────

  $ oc describe node gpu-worker-1 | grep nvidia
    nvidia.com/gpu:     1
    nvidia.com/gpu:     1    # 1 GPU allocatable
```

```
  Step 3: Install OpenShift AI → Creates DataScienceCluster
  ──────────────────────────────────────────────────────────

  After creating the DataScienceCluster CR, OpenShift AI
  automatically configures:
    • Istio control plane (for traffic routing)
    • Knative Serving (for autoscaling)
    • KServe controller (for InferenceService)
    • Dashboard (web UI for data scientists)
```

**Step 4: Create S3 Secret** (model storage credentials)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: llama3-s3-secret
  namespace: my-ai-project
type: Opaque
data:
  AWS_ACCESS_KEY_ID: <base64>
  AWS_SECRET_ACCESS_KEY: <base64>
  AWS_S3_ENDPOINT: <base64>
  AWS_S3_BUCKET: <base64>
```

**Step 5: Create ServingRuntime** (tells OpenShift HOW to serve)

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-nvidia-runtime
  namespace: my-ai-project
spec:
  supportedModelFormats:
    - name: vLLM
      autoSelect: true
  containers:
    - name: kserve-container
      image: quay.io/modh/vllm:latest
      args:
        - --model=/mnt/models
        - --tensor-parallel-size=1
        - --max-model-len=8192
        - --dtype=float16
      resources:
        limits:
          nvidia.com/gpu: 1     # Request 1 GPU
        requests:
          memory: 48Gi
          cpu: "8"
```

**Step 6: Create InferenceService** (tells OpenShift WHAT to serve)

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llama3-8b
  namespace: my-ai-project
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-nvidia-runtime
      storageUri: s3://my-bucket/models/llama-3-8b
      resources:
        limits:
          nvidia.com/gpu: 1
        requests:
          memory: 48Gi
          cpu: "8"
```

### 9.4 What Happens After You Apply

```
  You run: oc apply -f inferenceservice.yaml
       │
       ▼
  KServe controller sees new InferenceService
       │
       ▼
  Creates Knative Service + Deployment
       │
       ▼
  Scheduler places pod on GPU node (nvidia.com/gpu: 1)
       │
       ▼
  vLLM container starts:
       │
       ├──  1. Downloads model from S3 (~16 GB)    ← 2-10 min
       ├──  2. Loads weights into GPU memory        ← 30-60 sec
       ├──  3. Initializes PagedAttention KV-cache  ← 10-20 sec
       └──  4. Starts OpenAI-compatible API server  ← immediate
              │
              ▼
  Istio creates a Route:
    https://llama3-8b-my-ai-project.apps.cluster.example.com
       │
       ▼
  Ready to serve!
```

### 9.5 Using the Deployed Model

The model exposes an OpenAI-compatible API:

```bash
# Chat completion (same as OpenAI API)
curl https://llama3-8b-my-ai-project.apps.cluster.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3-8b",
    "messages": [
      {"role": "user", "content": "Explain containers in simple terms"}
    ],
    "max_tokens": 256,
    "temperature": 0.7
  }'
```

Because vLLM exposes an **OpenAI-compatible API**, any existing application
that calls OpenAI can switch to your self-hosted model by just changing the
base URL — no code changes needed.

### 9.6 Complete Data Flow

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                     Request Flow                                  │
  │                                                                   │
  │  Client App                                                       │
  │     │                                                             │
  │     │ HTTPS POST /v1/chat/completions                             │
  │     ▼                                                             │
  │  ┌─────────────┐                                                  │
  │  │ HAProxy      │  OpenShift Router                                │
  │  │ (TLS term.)  │  terminates TLS, routes by hostname              │
  │  └──────┬──────┘                                                  │
  │         │                                                         │
  │         ▼                                                         │
  │  ┌─────────────┐                                                  │
  │  │ Istio        │  Service Mesh                                    │
  │  │ Gateway      │  mTLS between services, traffic splitting        │
  │  └──────┬──────┘                                                  │
  │         │                                                         │
  │         ▼                                                         │
  │  ┌─────────────┐                                                  │
  │  │ Knative      │  Autoscaler                                      │
  │  │ Activator    │  If scaled to 0, wakes up a pod                  │
  │  └──────┬──────┘                                                  │
  │         │                                                         │
  │         ▼                                                         │
  │  ┌──────────────────────────────────────────┐                     │
  │  │            vLLM Pod (on GPU node)         │                     │
  │  │                                           │                     │
  │  │  ┌─────────────────────────────────────┐  │                     │
  │  │  │  vLLM Engine                         │  │                    │
  │  │  │                                      │  │                    │
  │  │  │  1. Tokenize input                   │  │                    │
  │  │  │  2. Add to continuous batch          │  │                    │
  │  │  │  3. Run transformer on GPU           │  │                    │
  │  │  │  4. PagedAttention for KV-cache      │  │                    │
  │  │  │  5. Generate tokens one by one       │  │                    │
  │  │  │  6. Detokenize output                │  │                    │
  │  │  │  7. Stream response back             │  │                    │
  │  │  └─────────────────────────────────────┘  │                     │
  │  │                                           │                     │
  │  │  GPU Memory Layout (8B model, 8K context): │                     │
  │  │  ┌─────────────────────────────────────┐  │                     │
  │  │  │  Model Weights     │  ~16 GB (FP16) │  │                     │
  │  │  │  KV Cache (Paged)  │  ~48 GB        │  │                     │
  │  │  │  Activations       │  ~4 GB         │  │                     │
  │  │  │  Free / Overhead   │  ~12 GB        │  │                     │
  │  │  └─────────────────────────────────────┘  │                     │
  │  │              80 GB Total (A100)            │                     │
  │  │  Note: KV-cache grows with --max-model-len│                     │
  │  │  and concurrent requests. vLLM pre-        │                     │
  │  │  allocates remaining GPU memory for cache. │                     │
  │  └──────────────────────────────────────────┘                     │
  │         │                                                         │
  │         ▼                                                         │
  │  Response streamed back through                                    │
  │  Istio → Router → Client                                          │
  └──────────────────────────────────────────────────────────────────┘
```

### 9.7 Monitoring the Deployment

```
  Prometheus Metrics from vLLM + DCGM:
  ─────────────────────────────────────

  ┌───────────────────────────────────────────────────────────┐
  │  Metric                        │  What It Tells You       │
  ├───────────────────────────────────────────────────────────┤
  │  vllm:num_requests_running     │  Active requests         │
  │  vllm:num_requests_waiting     │  Queue depth             │
  │  vllm:avg_generation_throughput│  Tokens/sec generated    │
  │  vllm:avg_prompt_throughput    │  Tokens/sec processed    │
  │  DCGM_FI_DEV_GPU_UTIL         │  GPU compute utilization │
  │  DCGM_FI_DEV_FB_USED          │  GPU memory used (MB)    │
  │  DCGM_FI_DEV_GPU_TEMP         │  GPU temperature         │
  │  DCGM_FI_DEV_POWER_USAGE      │  Power consumption (W)   │
  └───────────────────────────────────────────────────────────┘
```

---

## 10. Multi-GPU and Multi-Node Inference

For models larger than a single GPU (e.g., 70B+ parameters), vLLM supports
two strategies for splitting a model:

```
  Two ways to split a model across GPUs:
  ───────────────────────────────────────

  Tensor Parallelism (TP)              Pipeline Parallelism (PP)
  ─────────────────────────            ──────────────────────────
  Split WITHIN each layer              Split ACROSS layers
  Each GPU holds a slice               Each GPU holds entire layers
  of every layer's weights             but only a subset of them

  GPU 0: Layer0-PartA, Layer1-PartA    GPU 0: Layer 0, Layer 1
  GPU 1: Layer0-PartB, Layer1-PartB    GPU 1: Layer 2, Layer 3

  Needs fast GPU↔GPU link (NVLink)     Works over slower networks
  Best within a single node            Best across nodes
```

**Tensor parallelism** in action (4 GPUs in one node):

```
  Single GPU (8B model)          Tensor Parallel = 4 (70B model)
  ─────────────────────          ──────────────────────────────

  ┌─────────────┐                ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
  │   GPU 0      │                │ GPU 0  │ │ GPU 1  │ │ GPU 2  │ │ GPU 3  │
  │              │                │        │ │        │ │        │ │        │
  │  All layers  │                │Layer 0 │ │Layer 0 │ │Layer 0 │ │Layer 0 │
  │  All weights │                │Part A  │ │Part B  │ │Part C  │ │Part D  │
  │              │                ├────────┤ ├────────┤ ├────────┤ ├────────┤
  │              │                │Layer 1 │ │Layer 1 │ │Layer 1 │ │Layer 1 │
  │              │                │Part A  │ │Part B  │ │Part C  │ │Part D  │
  └─────────────┘                └────────┘ └────────┘ └────────┘ └────────┘
                                  ◄──── Connected via NVLink ────►

  --tensor-parallel-size=1       --tensor-parallel-size=4
```

For **multi-node** inference (model so large it needs GPUs across machines),
you combine both strategies:

```
  Node 1 (4x A100)              Node 2 (4x A100)
  Pipeline Stage 1               Pipeline Stage 2
  (Layers 0-15)                  (Layers 16-31)
  ─────────────────              ─────────────────
  ┌──┐┌──┐┌──┐┌──┐              ┌──┐┌──┐┌──┐┌──┐
  │G0││G1││G2││G3│◄─── NCCL ───►│G4││G5││G6││G7│
  └──┘└──┘└──┘└──┘   (RDMA/     └──┘└──┘└──┘└──┘
   TP=4 within node   InfiniBand) TP=4 within node

  --tensor-parallel-size=4
  --pipeline-parallel-size=2
```

**NCCL** (NVIDIA Collective Communications Library) is the library GPUs use to
talk to each other — it handles the data transfers needed when a model is
split. Within a node, NCCL uses NVLink (fast GPU-to-GPU links). Across nodes,
it uses RDMA over InfiniBand (high-bandwidth network) to minimize latency.

---

## 11. Knowledge Graph: How Everything Connects

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                   │
  │                    OpenShift Ecosystem                             │
  │                                                                   │
  │   Infrastructure ─────────► RHCOS ──────────► CRI-O               │
  │        │                      │                  │                 │
  │        │                      │ managed by       │ runs            │
  │        │                      ▼                  ▼                 │
  │        │                    MCO            Containers/Pods         │
  │        │                      │                  │                 │
  │        │                      │                  │ scheduled by    │
  │        ▼                      ▼                  ▼                 │
  │   Kubernetes ◄──────── Operators ────────► kube-scheduler         │
  │        │                   │                     │                 │
  │        │            ┌──────┴──────┐              │ considers       │
  │        │            │             │              │                 │
  │        │            ▼             ▼              ▼                 │
  │        │     GPU Operator    OLM          GPU Resources            │
  │        │         │            │           (nvidia.com/gpu)         │
  │        │         │            │                                    │
  │        │         ▼            ▼                                    │
  │        │     NFD ──► GPU    OperatorHub                            │
  │        │     Device Plugin     │                                   │
  │        │         │             │                                   │
  │        │         ▼             ▼                                   │
  │        │    GPU available   OpenShift AI                           │
  │        │    in cluster      Operator                               │
  │        │                       │                                   │
  │        │                       ▼                                   │
  │        │              ┌────────┼────────┐                          │
  │        │              │        │        │                          │
  │        │              ▼        ▼        ▼                          │
  │        │          KServe   Knative    Istio                        │
  │        │              │        │     (Service Mesh)                │
  │        │              ▼        │        │                          │
  │        │       InferenceService│        │                          │
  │        │              │        │        │                          │
  │        │              ▼        ▼        ▼                          │
  │        │         vLLM Pod ◄─ Scale ◄─ mTLS + Routing              │
  │        │              │       0→N                                  │
  │        │              ▼                                            │
  │        └───► Prometheus/DCGM ──► Grafana Dashboard                │
  │                    │                                               │
  │                    └──► KEDA (SLO-driven autoscaling)              │
  │                                                                   │
  └──────────────────────────────────────────────────────────────────┘
```

### 11.1 Dependency Map (What Installs Before What)

```
  Install Order for LLM Inference on OpenShift:
  ──────────────────────────────────────────────

  Level 0 (base):    OpenShift Cluster (3 control + N workers)
                       │
                       ▼
  Level 1 (infra):   Install these three operators (can be parallel):
                       ├── Node Feature Discovery (NFD)
                       ├── OpenShift Serverless (Knative)
                       └── OpenShift Service Mesh (Istio)
                       │
                       ▼
  Level 2 (GPU):     NVIDIA GPU Operator
                       (requires: NFD from Level 1)
                       │
                       ▼
  Level 3 (AI):      Red Hat OpenShift AI
                       (requires: Knative + Istio from Level 1)
                       │
                       ▼
  Level 4 (serve):   Create ServingRuntime + InferenceService
                       (requires: GPU Operator + OpenShift AI)
```

---

## 12. Common Pitfalls When Deploying LLMs on OpenShift

| Pitfall | What Happens | How to Avoid |
|---------|-------------|--------------|
| **Forgot NFD before GPU Operator** | GPU Operator can't find GPU nodes | Always install NFD first, verify node labels |
| **Insufficient GPU memory** | Pod OOMKilled or model fails to load | Check model size in FP16 + 30% overhead |
| **No `nvidia.com/gpu` in resource limits** | Pod scheduled on CPU-only node | Always set `limits.nvidia.com/gpu: N` |
| **Scale-to-zero with cold start** | First request after idle times out (model reload takes minutes) | Set `minReplicas: 1` for large models, or use PVC for faster model loading |
| **Wrong `--max-model-len`** | KV-cache allocation fails (too high) or truncates context (too low) | Match to your actual prompt/response lengths |
| **Missing Service Mesh / Serverless** | KServe fails to create routes | Install all prerequisite operators before OpenShift AI |

---

## 13. Summary: Choosing the Right Pieces

| What You Want | What You Use | Why |
|---------------|-------------|-----|
| Run containers at scale | OpenShift (Kubernetes) | Enterprise orchestration |
| Immutable, secure nodes | RHCOS | No config drift |
| Automate platform ops | Operators (CVO, MCO) | Self-healing platform |
| Use GPUs in containers | NVIDIA GPU Operator + NFD | Expose GPUs to K8s |
| Serve LLMs efficiently | vLLM + KServe | PagedAttention, continuous batching |
| Auto-scale LLM serving | KEDA + Prometheus metrics | SLO-driven scaling |
| Monitor GPU health | DCGM Exporter + Grafana | Real-time GPU metrics |
| Model governance | TrustyAI | Fairness, explainability |
| Store models | S3 / PVC / OCI (ModelCar) | Flexible model delivery |

---

## 14. References

- [Red Hat OpenShift Architecture Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/pdf/architecture/OpenShift_Container_Platform-4.14-Architecture-en-US.pdf)
- [OpenShift AI — Serving Large Models](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.22/html/serving_models/serving-large-models_serving-large-models)
- [Deploy LLM Inference on OpenShift AI](https://developers.redhat.com/articles/2025/11/03/deploy-llm-inference-service-openshift-ai)
- [Autoscaling vLLM with OpenShift AI](https://developers.redhat.com/articles/2025/10/02/autoscaling-vllm-openshift-ai)
- [KEDA vs Knative Autoscaling Performance](https://developers.redhat.com/articles/2025/11/26/autoscaling-vllm-openshift-ai-model-serving)
- [Why vLLM for AI Inference](https://developers.redhat.com/articles/2025/10/30/why-vllm-best-choice-ai-inference-today)
- [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-nfd.html)
- [NVIDIA GPU Architecture on OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/hardware_accelerators/nvidia-gpu-architecture)
- [OpenShift AI with vLLM and Spring AI](https://piotrminkowski.com/2025/05/12/openshift-ai-with-vllm-and-spring-ai/)
- [OpenShift AI MLPerf Benchmarks](https://www.redhat.com/en/blog/accelerating-generative-ai-adoption-red-hat-openshift-ai-achieves-impressive-results-mlperf-inference-benchmarks-vllm-runtime)

---

**In summary**: OpenShift wraps Kubernetes with enterprise guardrails
(immutable OS, operators, security), and OpenShift AI extends it into a full
AI inference platform (KServe + vLLM + GPU Operator). The operator pattern is
the thread that ties everything together — from OS updates to GPU drivers to
model autoscaling, it's all Watch → Compare → Act.
