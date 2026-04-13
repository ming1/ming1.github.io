---
title: "OpenShift Architecture: Deep Dive from Platform to Large Model Inference"
category: tech
tags: [openshift, kubernetes, containers, gpu, llm, inference, vllm, kserve, ai, cloud-native]
---

* TOC
{:toc}

> **How to read this article:**
> - **Section 0** defines all key terms used throughout
> - **Section 1** explains Kubernetes — the foundation OpenShift is built on
> - **Sections 2-7** cover OpenShift fundamentals (architecture, nodes, operators, networking, security)
> - **Sections 8-9** cover OpenShift AI for Large Model Inference (KServe, vLLM, GPU Operator, autoscaling)
> - **Sections 10-11** walk through a complete deployment example with multi-GPU support
> - **Section 15** shows how to run OpenShift locally on a Fedora VM (MicroShift, CRC, OKD)
> - If you already know Kubernetes, skip to **Section 6.4 (Operators)** — that's where OpenShift diverges.
> - If you only care about LLM serving, skip to **Section 8**.

## 0. Glossary: Key Terms

Before diving in, here are the main terms used throughout this article:

### Platform & Infrastructure

| Term | What It Is | Analogy |
|------|-----------|---------|
| **Kubernetes (K8s)** | Open-source system that automates deploying, scaling, and managing containers across a cluster of machines | A robot factory manager that decides which machine runs which task |
| **OpenShift** | Red Hat's enterprise Kubernetes distribution — K8s + security + tooling + support | Kubernetes in a hardened, ready-to-use package |
| **Container** | A lightweight, isolated process that bundles an application with its dependencies | A shipping container — same box runs anywhere |
| **Pod** | The smallest deployable unit in Kubernetes; one or more containers sharing network and storage | An apartment — containers are the rooms inside |
| **Node** | A physical or virtual machine in the cluster that runs pods | A server in the data center |
| **Cluster** | A set of nodes managed together by Kubernetes | The entire data center, managed as one unit |
| **Namespace** | A virtual partition inside a cluster for isolating resources | A folder that keeps one team's work separate from another |

### OpenShift-Specific

| Term | What It Is |
|------|-----------|
| **RHCOS** | Red Hat Enterprise Linux CoreOS — an immutable, container-optimized OS on every OpenShift node |
| **CRI-O** | Container Runtime Interface for OCI — the lightweight container runtime OpenShift uses (replaces Docker) |
| **Operator** | A custom controller that automates the management of an application or platform component using the Watch → Compare → Act loop |
| **CVO** | Cluster Version Operator — manages OpenShift cluster upgrades |
| **MCO** | MachineConfig Operator — manages OS-level configuration across all nodes |
| **OLM** | Operator Lifecycle Manager — installs, upgrades, and manages operators |
| **SCC** | Security Context Constraints — OpenShift's rules for what a container is allowed to do (run as root, access host network, etc.) |
| **Route** | OpenShift's way to expose a service to the internet with TLS termination (similar to Kubernetes Ingress) |
| **ImageStream** | An OpenShift abstraction that tracks container image tags and can trigger rebuilds/redeployments on change |

### AI / LLM Inference

| Term | What It Is |
|------|-----------|
| **LLM** | Large Language Model — an AI model (like Llama, GPT) trained on text to generate human-like responses |
| **Inference** | Using a trained model to generate predictions or responses (as opposed to training it) |
| **vLLM** | A high-performance LLM inference engine; the default serving runtime in OpenShift AI |
| **KServe** | A Kubernetes-native platform for serving ML models; orchestrates model deployment, scaling, and routing |
| **Knative** | A Kubernetes framework for serverless workloads; provides scale-to-zero and autoscaling for KServe |
| **Istio** | A service mesh that handles traffic routing, mTLS encryption, and observability between services |
| **KEDA** | Kubernetes Event-Driven Autoscaling — scales pods based on custom metrics (e.g., inference latency) |
| **InferenceService** | A KServe custom resource (CR) that defines WHAT model to serve and WHERE to find it |
| **ServingRuntime** | A KServe custom resource (CR) that defines HOW to serve a model (which engine, what arguments) |

### GPU & Hardware

| Term | What It Is |
|------|-----------|
| **GPU** | Graphics Processing Unit — specialized hardware for parallel computation; essential for LLM inference |
| **NVIDIA GPU Operator** | An operator that automates GPU driver installation, device plugin, and monitoring on OpenShift |
| **NFD** | Node Feature Discovery — scans node hardware and labels nodes (e.g., "this node has an NVIDIA GPU") |
| **DCGM** | Data Center GPU Manager — NVIDIA's tool for GPU monitoring; exports metrics to Prometheus |
| **MIG** | Multi-Instance GPU — hardware-level GPU partitioning (A100/H100+) for true memory isolation |
| **NCCL** | NVIDIA Collective Communications Library — handles GPU-to-GPU data transfer for multi-GPU inference |
| **NVLink** | High-speed GPU-to-GPU interconnect within a single node |
| **Tensor Parallelism (TP)** | Splitting each model layer across multiple GPUs — each GPU holds a slice of every layer |
| **Pipeline Parallelism (PP)** | Splitting model layers across GPUs — each GPU holds entire layers but only a subset |

### Model Precision

| Term | What It Is |
|------|-----------|
| **FP32** | 32-bit floating point — full precision, 4 GB per billion parameters |
| **FP16 / BF16** | 16-bit floating point — half precision, 2 GB per billion parameters, negligible quality loss |
| **INT8** | 8-bit integer quantization — 1 GB per billion parameters, minimal quality loss |
| **INT4 (GPTQ/AWQ)** | 4-bit integer quantization — 0.5 GB per billion parameters, noticeable loss on hard tasks |
| **PagedAttention** | vLLM's memory management technique — allocates GPU memory in small pages (like OS virtual memory) instead of large contiguous blocks, reducing waste from ~60% to ~5% |
| **KV-cache** | Key-Value cache — stores intermediate attention computation results so the model doesn't recompute them for each new token |
| **Continuous Batching** | Processing inference requests as they arrive rather than waiting for a fixed batch to fill — keeps GPUs busy |

---

## 1. Kubernetes: The Foundation

Before understanding OpenShift, you need to understand **Kubernetes** — the
open-source project that OpenShift is built on.

### 1.1 The Problem Kubernetes Solves

Imagine you have an application packaged as a container. Running one container
on one machine is easy. But in production you need:

- Multiple copies for high availability
- Spread across machines in case one fails
- Automatic restarts when a container crashes
- Rolling updates without downtime
- Resource limits so one app doesn't starve another

Doing all this by hand is error-prone. Kubernetes automates it.

### 1.2 Core Idea: Desired State

Kubernetes is a **desired-state system**. You tell it *what you want* (not
*how to do it*), and it figures out the rest:

```
  You say:                         Kubernetes does:
  ─────────                        ─────────────────
  "Run 3 copies of my app"        Find 3 nodes with enough CPU/memory
                                   Start containers on them
                                   Monitor them forever

  "Expose it on port 443"         Create a load balancer
                                   Route traffic to healthy pods

  "Update to version 2.0"         Start new pods with v2.0
                                   Wait until healthy
                                   Stop old v1.0 pods
                                   (zero-downtime rolling update)
```

### 1.3 Architecture in One Diagram

```
  ┌──────────────────────────────────────────────────────────────┐
  │                   Kubernetes Cluster                          │
  │                                                               │
  │  ┌─────────────────── Control Plane ───────────────────────┐  │
  │  │                                                          │  │
  │  │  ┌────────────┐  ┌──────┐  ┌───────────┐  ┌──────────┐  │  │
  │  │  │ API Server  │  │ etcd │  │ Scheduler  │  │Controller│  │  │
  │  │  │ (front door)│  │(state│  │(picks nodes│  │ Manager  │  │  │
  │  │  │             │  │ store│  │ for pods)  │  │(fix drift│  │  │
  │  │  │             │  │  )   │  │            │  │  )       │  │  │
  │  │  └────────────┘  └──────┘  └───────────┘  └──────────┘  │  │
  │  └──────────────────────────────────────────────────────────┘  │
  │                             │                                  │
  │                   "run this pod"                                │
  │                             │                                  │
  │         ┌───────────────────┼───────────────────┐              │
  │         ▼                   ▼                   ▼              │
  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
  │  │ Worker Node  │    │ Worker Node  │    │ Worker Node  │       │
  │  │              │    │              │    │              │       │
  │  │ ┌─────────┐  │    │ ┌─────────┐  │    │ ┌─────────┐  │      │
  │  │ │ kubelet  │  │    │ │ kubelet  │  │    │ │ kubelet  │  │     │
  │  │ └─────────┘  │    │ └─────────┘  │    │ └─────────┘  │      │
  │  │ ┌────┐┌────┐ │    │ ┌────┐┌────┐ │    │ ┌────┐       │      │
  │  │ │PodA││PodB│ │    │ │PodC││PodD│ │    │ │PodE│       │      │
  │  │ └────┘└────┘ │    │ └────┘└────┘ │    │ └────┘       │      │
  │  └─────────────┘    └─────────────┘    └─────────────┘        │
  └──────────────────────────────────────────────────────────────┘
```

### 1.4 Key Kubernetes Objects

| Object | What It Does | Example |
|--------|-------------|---------|
| **Pod** | Runs one or more containers | A vLLM inference server |
| **Deployment** | Manages N replicas of a pod, handles updates | "Run 3 copies of my web app" |
| **Service** | Stable network endpoint for a set of pods | Internal load balancer at `my-app:8080` |
| **Ingress** | Exposes a Service to outside traffic | Route `api.example.com` → Service |
| **ConfigMap** | Key-value config injected into pods | Database URLs, feature flags |
| **Secret** | Like ConfigMap but for sensitive data | Passwords, API keys, TLS certs |
| **Namespace** | Isolates resources between teams | `team-a` can't see `team-b`'s pods |
| **PersistentVolume (PV)** | Storage that outlives a pod | Database files, model weights |
| **Custom Resource (CR)** | User-defined object type — extends the API | `InferenceService`, `MachineConfig` |

### 1.5 What Kubernetes Does NOT Give You

Kubernetes is powerful but deliberately minimal. Out of the box, it does **not**
provide:

```
  What's Missing in Vanilla K8s        Who Fills the Gap
  ─────────────────────────────        ──────────────────
  An operating system for nodes         → RHCOS (OpenShift)
  A container image registry            → Quay / OpenShift Registry
  A web console / UI                    → OpenShift Console
  CI/CD pipelines                       → Tekton / OpenShift Pipelines
  OAuth / enterprise authentication     → OpenShift OAuth
  Automated cluster upgrades            → CVO Operator (OpenShift)
  GPU driver management                 → NVIDIA GPU Operator
  AI model serving framework            → KServe / OpenShift AI
  Security defaults (non-root, SCCs)    → OpenShift SCCs
```

This is exactly why OpenShift exists — it fills these gaps.

---

## 2. What Is OpenShift?

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

## 3. Motivation: Why OpenShift?

### 3.1 The Problem

Running containers in production is hard. A typical team faces:

| Challenge | What Goes Wrong |
|-----------|----------------|
| **Security** | Who can deploy what? Are images scanned? Are secrets managed? |
| **Day-2 Operations** | How do you upgrade 500 nodes without downtime? |
| **Multi-tenancy** | How do teams share a cluster safely? |
| **Consistency** | Dev, staging, prod must behave the same |
| **GPU/AI Workloads** | How do you schedule LLMs onto GPU nodes efficiently? |

### 3.2 OpenShift's Answer

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

## 4. Architecture Overview: The Layer Cake

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

## 5. Node Types

### 5.1 What Is a Node?

A **node** is a single machine — physical server or virtual machine — that
participates in the OpenShift cluster. Every node runs:

```
  ┌───────────────────────────────────────┐
  │         What Every Node Has           │
  │                                       │
  │  RHCOS          Immutable Linux OS    │
  │  CRI-O          Container runtime     │
  │  kubelet         Agent that receives  │
  │                  orders from the       │
  │                  control plane         │
  │  OVN-Kubernetes  Network plugin        │
  └───────────────────────────────────────┘
```

**Simple analogy**: If the cluster is a restaurant, each node is a person
working in it. The *control plane node* is the manager (decides what happens),
*worker nodes* are the cooks (do the actual work), and *infra nodes* are the
dishwashers and cleaners (keep the restaurant running but don't cook food).

```
  Relationship: Cluster → Node → Pod → Container

  Cluster          "the whole restaurant"
    └── Node       "one person / one machine"
         └── Pod   "one task that person is doing"
              └── Container   "the specific process running"
```

### 5.2 Node Roles

An OpenShift cluster has different kinds of nodes, each with a specific role:

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

| Node Type | Role | What Runs on It | Minimum Count |
|-----------|------|-----------------|---------------|
| **Control Plane** | The brain — decides where pods go | API server, etcd, scheduler, controllers | 3 (for HA) |
| **Worker** | The muscle — runs your applications | User pods, app containers | 2+ |
| **GPU Worker** | Worker with accelerator hardware | GPU device plugin, vLLM / AI pods | 1+ (for AI) |
| **Infra** | The plumbing — runs platform services | Router, monitoring, logging, registry | Optional |

### 5.3 How the Control Plane Talks to Nodes

The kubelet on each worker node maintains a constant connection to the API
server. This is how pods get scheduled:

```
  ┌─────────────────────────────┐
  │       Control Plane          │
  │                              │
  │  Scheduler: "Pod X needs     │
  │  2 CPU + 1 GPU. Node 5 has   │
  │  room. Send it there."       │
  └──────────────┬───────────────┘
                 │
                 │  "Run Pod X"
                 ▼
  ┌─────────────────────────────┐
  │     Worker Node 5 (GPU)      │
  │                              │
  │  kubelet receives order       │
  │       │                      │
  │       ▼                      │
  │  CRI-O pulls image           │
  │       │                      │
  │       ▼                      │
  │  Container starts on GPU     │
  │       │                      │
  │       ▼                      │
  │  kubelet reports back:       │
  │  "Pod X is Running"          │
  └─────────────────────────────┘
```

The kubelet also continuously monitors its pods. If a container crashes,
kubelet detects it and restarts it automatically. It reports node health
(CPU, memory, GPU availability) back to the control plane every few seconds,
so the scheduler always knows which nodes have room for new pods.

### 5.4 Node Lifecycle

Nodes are not static — OpenShift manages their lifecycle:

```
  Add a Node               Remove a Node
  ──────────               ─────────────
  1. New machine boots     1. Mark node as
     with RHCOS               unschedulable
                               (cordon)
  2. Ignition config       2. Move pods to
     applied (network,        other nodes
     disk, kubelet)            (drain)

  3. kubelet contacts      3. Delete node
     API server               from cluster
     ("I'm ready")

  4. Node appears in       4. Machine can be
     "oc get nodes"           repurposed or
                              decommissioned
```

### 5.5 Special Case: Single Node OpenShift (SNO)

For edge deployments or small AI inference setups, OpenShift can run on a
**single machine**. One server acts as both control plane and worker:

```
  Full Cluster (6+ machines)     Single Node OpenShift (1 machine)
  ──────────────────────────     ────────────────────────────────

  ┌────┐┌────┐┌────┐             ┌────────────────────────────┐
  │ CP ││ CP ││ CP │             │  Single Node               │
  └────┘└────┘└────┘             │                            │
  ┌────┐┌────┐┌────┐             │  Control Plane roles       │
  │ W1 ││ W2 ││ W3 │             │  + Worker roles            │
  └────┘└────┘└────┘             │  + Infra roles             │
                                  │  All on one machine        │
  HA: Yes                        └────────────────────────────┘
  Cost: High
                                  HA: No (single point of failure)
                                  Cost: Low
                                  Good for: Edge AI, factory,
                                  retail store, dev/test
```

---

## 6. Building Blocks: Deep Dive

### 6.1 RHCOS — Red Hat Enterprise Linux CoreOS

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

### 6.2 CRI-O — Container Runtime

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

### 6.3 Kubernetes Core Components

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

#### kube-apiserver — The Front Door

The API server is the **only** component that talks to etcd. Everything else
— the CLI, the web console, operators, kubelet — talks through it.

```
  Who Talks to the API Server:
  ────────────────────────────

  oc get pods ─────────────────────────────────────────┐
  Web Console ─────────────────────────────────────────┤
  Operators ───────────────────────────────────────────┤
  kubelet (every node) ────────────────────────────────┤
  kube-scheduler ──────────────────────────────────────┤
  kube-controller-manager ─────────────────────────────┤
                                                       ▼
                                              ┌──────────────┐
                                              │ kube-apiserver│
                                              │              │
                                              │ 1. Authenticate│
                                              │    (who are you?)│
                                              │ 2. Authorize  │
                                              │    (can you do │
                                              │     this?)     │
                                              │ 3. Admission  │
                                              │    (is it valid?│
                                              │     mutate it?) │
                                              │ 4. Persist    │
                                              │    (write to   │
                                              │     etcd)      │
                                              └──────────────┘
```

Every request goes through three gates before it reaches etcd:
- **Authentication**: Are you who you claim to be? (OAuth token, certificate, service account)
- **Authorization**: Are you allowed to do this? (RBAC rules)
- **Admission**: Is this request valid? Should we modify it? (e.g., inject default SCCs, add labels)

#### etcd — The Cluster Memory

etcd is a **distributed key-value store** that holds the entire cluster state.
If etcd is lost and has no backup, the cluster is gone.

```
  What etcd Stores (examples):
  ────────────────────────────

  Key                                    Value
  ───                                    ─────
  /registry/pods/my-ns/web-app-xyz       {image: nginx, replicas: 3, ...}
  /registry/nodes/worker-1               {status: Ready, cpu: 16, mem: 64Gi}
  /registry/secrets/my-ns/db-password    {data: base64-encoded-secret}
  /registry/deployments/my-ns/llama3     {replicas: 1, gpu: 1, ...}
```

**Key facts:**
- Runs as 3 replicas on the 3 control plane nodes (Raft consensus — 2 of 3
  must agree for any write, so the cluster survives losing 1 node)
- Stores both the **desired state** (what you asked for) and the **actual
  state** (what currently exists) — controllers compare the two
- Performance-sensitive: etcd latency directly affects how fast the cluster
  responds. OpenShift recommends SSD/NVMe storage for etcd

```
  How Raft Consensus Works (simplified):
  ───────────────────────────────────────

  etcd-1 (Leader)     etcd-2              etcd-3
  ───────────────     ──────              ──────
  "Write X=5"  ──────► "I agree" ──┐
       │                            │
       │               "I agree" ──┘
       │                     ▲
       └─────────────────────┘
  Result: 2/3 agree → Write committed
  (works even if etcd-3 is temporarily down)
```

#### kube-scheduler — The Matchmaker

When a new pod needs to run, the scheduler decides **which node** gets it.
It doesn't just pick a random node — it runs through a scoring algorithm:

```
  New pod arrives: "I need 4 CPU, 32Gi RAM, 1 nvidia.com/gpu"
       │
       ▼
  Phase 1: FILTER (eliminate nodes that can't work)
       │
       ├── Node 1: 8 CPU, 16Gi RAM, no GPU  → ✗ not enough RAM, no GPU
       ├── Node 2: 16 CPU, 64Gi RAM, no GPU → ✗ no GPU
       ├── Node 3: 16 CPU, 64Gi RAM, 1 GPU  → ✓ passes
       └── Node 4: 32 CPU, 128Gi RAM, 4 GPU → ✓ passes
       │
       ▼
  Phase 2: SCORE (rank the surviving nodes)
       │
       ├── Node 3: score 60 (tight fit, less room for future pods)
       └── Node 4: score 85 (more headroom, better balanced)
       │
       ▼
  Result: Pod assigned to Node 4
```

**Factors the scheduler considers:**
- Resource requests (CPU, memory, GPU)
- Node affinity / anti-affinity ("put me near X" / "keep me away from Y")
- Taints and tolerations ("only GPU pods go on GPU nodes")
- Pod topology spread ("spread replicas across failure zones")
- Priority classes ("high-priority pods can preempt low-priority ones")

#### kube-controller-manager — The Fixer

The controller manager runs dozens of **reconciliation loops** — each one
watches a specific resource type and fixes any drift between desired and actual
state.

```
  Examples of Controllers Inside kube-controller-manager:
  ──────────────────────────────────────────────────────

  ReplicaSet Controller
  ─────────────────────
  Desired: 3 replicas        Actual: 2 running
  Action: "Start 1 more pod"

  Node Controller
  ───────────────
  Desired: all nodes healthy  Actual: Node 5 hasn't
                               reported in 5 minutes
  Action: "Mark Node 5 as NotReady,
           reschedule its pods elsewhere"

  Job Controller
  ──────────────
  Desired: run batch job      Actual: job completed
  Action: "Clean up pod, mark job as Succeeded"

  Endpoint Controller
  ───────────────────
  Desired: Service points     Actual: Pod C crashed,
           to Pods A, B, C    only A, B running
  Action: "Remove Pod C from the Service's
           endpoint list so traffic stops going to it"
```

**How it relates to Operators**: The kube-controller-manager handles
*built-in* Kubernetes objects (Deployments, ReplicaSets, Nodes, Jobs).
Operators (Section 6.4) extend this same pattern to *custom* objects like
`InferenceService`, `MachineConfig`, or `ClusterVersion`.

| Component | Job | Key Detail |
|-----------|-----|------------|
| **kube-apiserver** | Front door for all requests | Every `oc` command, every operator, hits this API |
| **etcd** | Stores all cluster state | Consensus via Raft; 3 replicas minimum |
| **kube-scheduler** | Assigns pods to nodes | Considers CPU, memory, GPU, affinity, taints |
| **kube-controller-manager** | Reconciliation loops | "Desired state → Actual state" for deployments, replicasets, etc. |

### 6.4 Operators — The Heart of OpenShift

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

### 6.5 Networking

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

### 6.6 Image Registry

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

### 6.7 Security Model

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

## 7. Observability Stack

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
This is what makes SLO-driven autoscaling (Section 9) possible.

---

## 8. OpenShift AI: The AI/ML Platform Layer

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

### 8.1 OpenShift AI Architecture (Single-Model Serving)

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

### 8.2 Key Components for LLM Inference

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

### 8.3 GPU Memory Sizing Guide

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

### 8.4 Quantization: Trading Precision for Speed

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

## 9. Autoscaling for LLM Inference

Traditional autoscaling (CPU %, request count) doesn't work well for LLMs
because GPU utilization and token throughput are what matter.

### 9.1 KEDA vs Knative Autoscaling

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

### 9.2 Autoscaling Flow

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

## 10. End-to-End Example: Deploying Llama 3 on OpenShift AI

Let's walk through a real scenario: deploying **Meta Llama 3 8B** for inference
on OpenShift AI with vLLM.

### 10.1 The Problem We're Solving

A company wants to:
- Host their own LLM (not send data to OpenAI) for **data privacy**
- Serve it as a REST API that's **OpenAI-compatible**
- **Auto-scale** based on demand (scale down at night, up during business hours)
- **Monitor** GPU utilization and response latency

### 10.2 Prerequisites

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

### 10.3 Step-by-Step Deployment

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

### 10.4 What Happens After You Apply

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

### 10.5 Using the Deployed Model

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

### 10.6 Complete Data Flow

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

### 10.7 Monitoring the Deployment

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

## 11. Multi-GPU and Multi-Node Inference

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

## 12. Knowledge Graph: How Everything Connects

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

### 12.1 Dependency Map (What Installs Before What)

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

## 13. Common Pitfalls When Deploying LLMs on OpenShift

| Pitfall | What Happens | How to Avoid |
|---------|-------------|--------------|
| **Forgot NFD before GPU Operator** | GPU Operator can't find GPU nodes | Always install NFD first, verify node labels |
| **Insufficient GPU memory** | Pod OOMKilled or model fails to load | Check model size in FP16 + 30% overhead |
| **No `nvidia.com/gpu` in resource limits** | Pod scheduled on CPU-only node | Always set `limits.nvidia.com/gpu: N` |
| **Scale-to-zero with cold start** | First request after idle times out (model reload takes minutes) | Set `minReplicas: 1` for large models, or use PVC for faster model loading |
| **Wrong `--max-model-len`** | KV-cache allocation fails (too high) or truncates context (too low) | Match to your actual prompt/response lengths |
| **Missing Service Mesh / Serverless** | KServe fails to create routes | Install all prerequisite operators before OpenShift AI |

---

## 14. Summary: Choosing the Right Pieces

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

## 15. Appendix: Running OpenShift Locally on Fedora

You don't need a data center to try OpenShift. Here are three ways to run it
on a single Fedora machine, from lightest to heaviest.

### 15.1 Choosing the Right Option

```
  ┌──────────────────────────────────────────────────────────────────┐
  │               Which Local OpenShift Is Right for You?             │
  │                                                                   │
  │  Feature              MicroShift       CRC (OpenShift)  CRC (OKD) │
  │  ──────────           ──────────       ───────────────  ───────── │
  │  Min RAM              2 GB             9 GB             9 GB      │
  │  Min CPU              2 cores          4 cores          4 cores   │
  │  Min Disk             ~2 GB            35 GB            35 GB     │
  │  Runs in VM?          No (on host)     Yes (libvirt)    Yes       │
  │  Red Hat account?     No               Yes (free)       No        │
  │  Web Console?         No               Yes              Yes       │
  │  OperatorHub / OLM?   No               Yes              Yes       │
  │  Full OpenShift API?  Subset (core)    Full             Full      │
  │  Startup time         ~1-2 min         ~15-20 min       ~15-20 min│
  │  Best for             Edge, learning   Full dev/test    Dev/test  │
  │                       basic K8s        with operators   no sub    │
  └──────────────────────────────────────────────────────────────────┘
```

**Decision guide:**
- Just want to learn pods/deployments/services? → **MicroShift**
- Need the full web console, OperatorHub, or to test KServe/vLLM? → **CRC (OpenShift)**
- Same as above but no Red Hat account? → **CRC (OKD)**

### 15.2 Option A: MicroShift (Lightest)

MicroShift packages the Kubernetes API server, etcd, kubelet, and CRI-O into
a **single systemd service**. It runs directly on the host — no nested VM.

> **Note**: MicroShift is officially supported on RHEL 9. On Fedora, it runs
> via community COPR builds or the upstream quick-install script. It works
> well but is not covered by Red Hat support.

**Install on Fedora:**

```bash
# Method 1: Upstream quick-install script (recommended)
# Detects your Fedora version automatically
curl -s https://microshift-io.github.io/microshift/quickrpm.sh | sudo bash

# Method 2: COPR repository (if Method 1 doesn't work)
# Check https://copr.fedorainfracloud.org/coprs/g/redhat-et/microshift/
# for available Fedora versions before enabling
sudo dnf copr enable -y @redhat-et/microshift
sudo dnf install -y microshift openshift-clients
```

**Configure firewall:**

```bash
# Allow pod and service network traffic
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16

# Allow API server, HTTP, and HTTPS
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

**Start and verify:**

```bash
# Start MicroShift
sudo systemctl enable --now microshift

# Watch startup progress (Ctrl+C to exit)
sudo journalctl -u microshift -f

# Set up kubeconfig for your user
mkdir -p ~/.kube
sudo cp /var/lib/microshift/resources/kubeadmin/kubeconfig ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# Verify — wait 1-2 minutes for all pods to start
oc get nodes
oc get pods -A
```

**Expected output when ready:**

```
  $ oc get nodes
  NAME        STATUS   ROLES                         AGE   VERSION
  fedora-vm   Ready    control-plane,master,worker    3m    v1.28.x

  $ oc get pods -A
  NAMESPACE                  NAME                         READY   STATUS
  openshift-dns              dns-default-xxxxx            2/2     Running
  openshift-dns              node-resolver-xxxxx          1/1     Running
  openshift-ingress          router-default-xxxxx         1/1     Running
  openshift-ovn-kubernetes   ovnkube-master-xxxxx         4/4     Running
  openshift-ovn-kubernetes   ovnkube-node-xxxxx           1/1     Running
  openshift-service-ca       service-ca-xxxxx             1/1     Running
```

**Deploy a test app:**

```bash
# Create a project and deploy nginx
oc new-project test
oc create deployment hello --image=nginx --port=80
oc expose deployment hello --port=80
oc expose service hello --hostname=hello.test.example.com

# Verify
oc get pods -n test
curl -H "Host: hello.test.example.com" http://localhost
```

### 15.3 Option B: OpenShift Local / CRC (Full OpenShift)

CRC runs a **full single-node OpenShift cluster** inside a libvirt VM.
You get the web console, OperatorHub, and the complete OpenShift API.

> **Requirements**: 4 CPU cores, 9 GB free RAM (16 GB total recommended),
> 35 GB disk, and a free [Red Hat Developer account](https://developers.redhat.com)
> for the pull secret.

**Install on Fedora:**

```bash
# Step 1: Install virtualization dependencies
sudo dnf install -y libvirt NetworkManager qemu-kvm

# Step 2: Download CRC from Red Hat Console
#   Go to: https://console.redhat.com/openshift/create/local
#   Download:
#     - crc-linux-amd64.tar.xz   (the tool)
#     - pull-secret.txt           (click "Copy pull secret")

# Step 3: Extract and install
cd ~/Downloads
tar xvf crc-linux-amd64.tar.xz
mkdir -p ~/.local/bin
install crc-linux-*-amd64/crc ~/.local/bin/crc

# Make sure ~/.local/bin is in PATH
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

**Setup and start:**

```bash
# One-time setup: configures libvirt, downloads VM image (~4 GB)
crc setup

# Start the cluster (takes ~15-20 minutes first time)
# Paste your pull secret when prompted
crc start

# After startup, CRC prints login credentials:
#   developer / developer  (regular user)
#   kubeadmin / <random>    (admin user)
```

**Access the cluster:**

```bash
# Set up oc CLI
eval $(crc oc-env)

# Login as developer
oc login -u developer -p developer \
  https://api.crc.testing:6443

# Login as admin
oc login -u kubeadmin -p $(crc console --credentials \
  | grep kubeadmin | awk -F"'" '{print $2}') \
  https://api.crc.testing:6443

# Open web console in browser
crc console
```

**Lifecycle commands:**

```bash
crc stop       # Shut down the VM (preserves state)
crc start      # Restart (much faster after first time)
crc delete     # Delete the VM entirely
crc status     # Check if running
```

### 15.4 Option C: OKD via CRC (No Red Hat Subscription)

OKD is the **community distribution** of OpenShift, built on Fedora CoreOS.
Same CRC tool, but uses the `okd` preset — no pull secret needed.

```bash
# Install CRC (same as Option B steps 1-3 above)
sudo dnf install -y libvirt NetworkManager qemu-kvm
# ... download and extract crc as shown in Option B ...

# Set OKD preset BEFORE running setup
crc config set preset okd

# Optional: disable telemetry
crc config set consent-telemetry no

# Setup and start (no pull secret needed)
crc setup
crc start

# Access
eval $(crc oc-env)
oc login -u developer -p developer https://api.crc.testing:6443
```

### 15.5 Comparison: What Runs Where

```
  What's Inside Each Option:
  ──────────────────────────

  MicroShift                    CRC (OpenShift / OKD)
  ──────────                    ─────────────────────
  ┌──────────────────────┐      ┌──────────────────────────────┐
  │  Your Fedora Host     │      │  Your Fedora Host             │
  │                       │      │                               │
  │  ┌─────────────────┐  │      │  ┌───────────────────────┐    │
  │  │ microshift.service│  │      │  │  libvirt VM (RHCOS)    │   │
  │  │                  │  │      │  │                        │   │
  │  │ • API server     │  │      │  │  • Full control plane  │   │
  │  │ • etcd           │  │      │  │  • etcd (3-member sim) │   │
  │  │ • kubelet        │  │      │  │  • Web console         │   │
  │  │ • CRI-O          │  │      │  │  • OperatorHub / OLM   │   │
  │  │ • OVN networking │  │      │  │  • Image registry      │   │
  │  │ • CoreDNS        │  │      │  │  • Prometheus/Grafana   │   │
  │  │                  │  │      │  │  • Router (HAProxy)    │   │
  │  │ No: OLM, console,│  │      │  │  • CRI-O + kubelet     │   │
  │  │ registry, Prom.  │  │      │  │                        │   │
  │  └─────────────────┘  │      │  └───────────────────────┘    │
  └──────────────────────┘      └──────────────────────────────┘

  ~200 MB memory overhead         ~8 GB memory overhead
```

### 15.6 Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| MicroShift COPR: "Chroot not found" | COPR doesn't have a build for your Fedora version | Use the quick-install script instead: `curl -s https://microshift-io.github.io/microshift/quickrpm.sh \| sudo bash` |
| MicroShift: pods stuck in `ContainerCreating` | CRI-O can't pull images from `registry.redhat.io` | Trust the GPG key: `sudo podman image trust set -f /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release registry.access.redhat.com` |
| CRC: `crc start` hangs | Not enough RAM available | Close other apps; ensure 9 GB free RAM; check with `free -h` |
| CRC: libvirt permission denied | User not in libvirt group | `sudo usermod -aG libvirt $USER` then log out and back in |
| CRC: DNS not resolving `*.crc.testing` | NetworkManager not managing DNS | Ensure NetworkManager is running: `sudo systemctl enable --now NetworkManager` |

---

## 16. References

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
- [MicroShift Upstream — GitHub](https://github.com/microshift-io/microshift)
- [Run MicroShift on Fedora — ComputingForGeeks](https://computingforgeeks.com/run-microshift-rhel-fedora/)
- [CRC Installation Documentation](https://crc.dev/docs/installing/)
- [OKD on Fedora with CRC — Fedora Magazine](https://fedoramagazine.org/okd-on-fedora-workstation-with-crc/)
- [Red Hat OpenShift Local](https://developers.redhat.com/products/openshift-local)

---

**In summary**: OpenShift wraps Kubernetes with enterprise guardrails
(immutable OS, operators, security), and OpenShift AI extends it into a full
AI inference platform (KServe + vLLM + GPU Operator). The operator pattern is
the thread that ties everything together — from OS updates to GPU drivers to
model autoscaling, it's all Watch → Compare → Act.
