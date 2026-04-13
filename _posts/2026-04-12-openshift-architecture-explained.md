---
title: "OpenShift Architecture: Deep Dive from Platform to Large Model Inference"
category: tech
tags: [openshift, kubernetes, containers, gpu, llm, inference, vllm, kserve, ai, cloud-native]
---

> **Note**: This article was generated entirely by AI (Claude) through an
> interactive conversation. The content has been reviewed for technical
> accuracy but may contain errors. Please verify critical details against
> official documentation before using in production.

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

Running containers in production is hard. Kubernetes gives you the engine, but
you still need to build the car around it. A typical team building on vanilla
Kubernetes faces these challenges:

| Challenge | What Goes Wrong | Real-World Example |
|-----------|----------------|--------------------|
| **Security** | Who can deploy what? Are images scanned? Are secrets managed? | A developer accidentally deploys a container running as root — it gets compromised and reads secrets from the host |
| **Day-2 Operations** | How do you upgrade 500 nodes without downtime? | A kernel security patch arrives — someone must SSH into each node, update it, reboot, and verify pods came back |
| **Multi-tenancy** | How do teams share a cluster safely? | Team A's runaway pod uses all GPU memory, starving Team B's inference service |
| **Consistency** | Dev, staging, prod must behave the same | "It works on my laptop" — dev uses Docker, CI uses containerd, prod uses CRI-O, and the image behaves differently |
| **GPU/AI Workloads** | How do you schedule LLMs onto GPU nodes efficiently? | GPU drivers must be installed on each node manually, and there's no way to monitor GPU temperature or memory from Kubernetes |

**The DIY Kubernetes tax**: Teams running vanilla Kubernetes spend significant
time assembling, integrating, and maintaining all the tooling around it:

```
  What You Must Build Yourself on Vanilla Kubernetes:
  ───────────────────────────────────────────────────

  ┌─────────────────────────────────────────────────────────────┐
  │  Need                     │  You must find, install,        │
  │                           │  configure, and maintain:       │
  ├─────────────────────────────────────────────────────────────┤
  │  Container registry       │  Harbor or Docker Registry      │
  │  Ingress / TLS            │  nginx-ingress + cert-manager   │
  │  Authentication           │  Dex + OIDC provider            │
  │  Monitoring               │  Prometheus + Grafana + Loki    │
  │  CI/CD                    │  ArgoCD + Tekton or Jenkins     │
  │  Image scanning           │  Trivy or Clair                 │
  │  Secret management        │  Vault or Sealed Secrets        │
  │  OS management            │  Ansible playbooks for patching │
  │  Cluster upgrades         │  kubeadm upgrade (manual)       │
  │  GPU support              │  NVIDIA device plugin + drivers │
  │  Service mesh             │  Istio (manual install)         │
  │  Web UI                   │  Kubernetes Dashboard (limited) │
  ├─────────────────────────────────────────────────────────────┤
  │  Total: 12+ tools from different vendors,                   │
  │  each with its own release cycle, docs, and bugs.           │
  │  You are the integrator.                                    │
  └─────────────────────────────────────────────────────────────┘
```

### 3.2 OpenShift's Answer

OpenShift solves this by providing an **integrated, self-managing platform**
where all these components are pre-assembled, tested together, and upgraded
as one unit:

```
  ┌─────────────────────────────────────────────────────────────┐
  │  Need                     │  OpenShift provides:            │
  ├─────────────────────────────────────────────────────────────┤
  │  Container registry       │  Built-in (+ Quay)              │
  │  Ingress / TLS            │  Routes (HAProxy) + auto certs  │
  │  Authentication           │  OAuth built-in                 │
  │  Monitoring               │  Prometheus + Grafana included  │
  │  CI/CD                    │  OpenShift Pipelines (Tekton)   │
  │  Image scanning           │  Integrated + admission control │
  │  Secret management        │  Built-in + Vault integration   │
  │  OS management            │  MCO (automatic, node by node)  │
  │  Cluster upgrades         │  CVO (one command: oc adm       │
  │                           │  upgrade --to=4.16.5)           │
  │  GPU support              │  GPU Operator (one click)       │
  │  Service mesh             │  OpenShift Service Mesh          │
  │  Web UI                   │  Full web console               │
  ├─────────────────────────────────────────────────────────────┤
  │  Total: 1 platform, 1 vendor, 1 upgrade path.              │
  │  Red Hat is the integrator.                                 │
  └─────────────────────────────────────────────────────────────┘
```

**The developer workflow** — from code to production in one platform:

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

### 3.3 Who Uses OpenShift and Why

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                     Typical OpenShift Users                       │
  │                                                                   │
  │  Role                    Why They Choose OpenShift                │
  │  ────                    ─────────────────────────                │
  │                                                                   │
  │  Platform Engineer       "I need to give 20 teams a secure        │
  │                           cluster without them breaking each      │
  │                           other. OpenShift's SCCs, RBAC, and      │
  │                           namespaces give me guardrails."         │
  │                                                                   │
  │  DevOps / SRE            "I need to upgrade 200 nodes without     │
  │                           paging anyone at 3 AM. The CVO and      │
  │                           MCO handle rolling upgrades for me."    │
  │                                                                   │
  │  Data Scientist          "I need to deploy a 70B LLM with GPU     │
  │                           access and autoscaling. OpenShift AI     │
  │                           + vLLM + KServe gives me that without   │
  │                           learning Kubernetes internals."         │
  │                                                                   │
  │  Security / Compliance   "I need to prove that no container       │
  │                           runs as root and all images are          │
  │                           scanned. OpenShift enforces this         │
  │                           by default, not by policy we hope        │
  │                           people follow."                         │
  │                                                                   │
  │  Enterprise Architect    "I need one platform that works on        │
  │                           bare metal, AWS, Azure, and GCP with    │
  │                           the same API. OpenShift runs anywhere    │
  │                           with a consistent experience."          │
  └──────────────────────────────────────────────────────────────────┘
```

### 3.4 The Tradeoffs

OpenShift is not free and not for everyone. Here's an honest look:

```
  Advantages                          Tradeoffs
  ──────────                          ──────────
  ✓ Everything integrated and tested  ✗ Subscription cost ($$)
  ✓ Red Hat support (24/7)            ✗ Opinionated — fewer choices
  ✓ Automated upgrades (CVO + MCO)     (CRI-O only, no Docker)
  ✓ Security by default (non-root)    ✗ Heavier than vanilla K8s
  ✓ Web console + OperatorHub           (more memory, more pods)
  ✓ Runs on any infra                 ✗ Learning curve for K8s users
  ✓ GPU/AI ready (Operators)            (Routes, SCCs, ImageStreams
                                         are OpenShift-specific)
```

**When vanilla Kubernetes might be enough:**
- Small team, single cluster, no compliance requirements
- You enjoy assembling tools and have time to maintain them
- Budget is extremely tight (OpenShift subscriptions start ~$50K/year)

**When OpenShift pays for itself:**
- Multiple teams sharing clusters (multi-tenancy)
- Regulated industries (finance, healthcare, government)
- GPU/AI workloads that need Operator-driven automation
- Operations team is small and can't babysit cluster upgrades

### 3.5 OpenShift vs OKD: Open Source, But Not Free

OpenShift's source code is fully **open source** (Apache 2.0). You can read
every line on GitHub. So why can't you just use it for free?

**You can** — the free version is called **OKD**. What you pay for with the
Red Hat subscription is not the code, but the engineering and support around it:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │           What the Subscription Actually Buys                     │
  │                                                                   │
  │  The CODE is free.        What costs money is:                    │
  │  ────────────────         ─────────────────────                   │
  │                                                                   │
  │  1. Pre-built, tested binaries                                    │
  │     Red Hat compiles, runs thousands of integration tests, and    │
  │     ships known-good container images. You don't build it.        │
  │                                                                   │
  │  2. Certified ecosystem                                           │
  │     GPU Operator, storage drivers, ISV apps — all tested          │
  │     against YOUR version. "It works together" is the value.       │
  │                                                                   │
  │  3. Security response                                             │
  │     CVE in etcd? Red Hat patches it, rebuilds, pushes update.     │
  │     You run "oc adm upgrade" and you're done.                     │
  │     Without subscription: you track CVEs yourself.                │
  │                                                                   │
  │  4. 24/7 Support                                                  │
  │     Cluster won't upgrade? GPU Operator broken? Open a case,      │
  │     get a Red Hat engineer on a call.                              │
  │                                                                   │
  │  5. Long-term stability                                           │
  │     Red Hat backports security fixes to older versions.            │
  │     You're not forced onto the bleeding edge.                     │
  └──────────────────────────────────────────────────────────────────┘
```

**Side-by-side comparison:**

```
  Red Hat OpenShift (OCP)            OKD (Community)
  ───────────────────────            ───────────────
  Based on: RHCOS                    Based on: Fedora CoreOS
  Images: registry.redhat.io         Images: quay.io/openshift
  Support: Red Hat 24/7              Support: GitHub issues, community
  CVE patches: Red Hat team          CVE patches: Community, best-effort
  Certified Operators: Yes           Certified Operators: No
  Cost: ~$50K+/year                  Cost: Free
  Stability: Enterprise-grade        Stability: Good, but less testing

  Same Kubernetes, same Operators, same oc CLI.
  OKD = "OpenShift without the Red Hat safety net."
```

**"But can't AI solve my OKD issues instead of paying for support?"**

Partly — AI tools (like Claude, ChatGPT) can help debug many Kubernetes
and OpenShift problems. But the subscription value goes beyond Q&A:

```
  What AI Can Do                   What AI Cannot Do
  ──────────────                   ─────────────────
  ✓ Explain error messages         ✗ Build and ship patched binaries
  ✓ Suggest debugging steps        ✗ Backport a CVE fix to your
  ✓ Help write YAML manifests        specific OCP version
  ✓ Explain Operator logs          ✗ Access your cluster and diagnose
  ✓ Teach you Kubernetes             a networking issue live
                                   ✗ Guarantee a certified Operator
                                     works with your GPU hardware
                                   ✗ Provide an SLA ("fix in 4 hours")
                                   ✗ Sign the compliance audit report
                                     saying "vendor supports this"
```

In practice, many small teams successfully run OKD with AI-assisted
troubleshooting. The subscription becomes essential when you need **SLAs,
compliance certification, and someone accountable** — things no AI can sign.

**"But why not just hire engineers to cover the remaining 20%?"**

You can. Some companies do. Here's the real math:

```
  Option A: Pay Red Hat               Option B: Hire Your Own Team
  ────────────────────               ─────────────────────────────
  ~$50-200K/year subscription         1-2 senior K8s/OpenShift engineers
  (depends on cluster size)           at $150-250K/year each = $300-500K

  What you get:                       What you get:
  • 200+ Red Hat engineers            • 1-2 people who know YOUR cluster
    working on OpenShift full-time    • They can fix things fast
  • Tested upgrade paths             • They build custom tooling
  • Certified partner ecosystem
  • Backported CVE patches            What you risk:
  • Compliance documentation          • They quit → single point of failure
                                      • They go on vacation → no coverage
  What you don't get:                 • They can't test every GPU driver +
  • Custom internal tooling             kernel + OpenShift version combo
  • Deep knowledge of YOUR              (Red Hat has a hardware lab for this)
    specific cluster quirks           • You still need to build, patch, and
                                        ship your own binaries
                                      • Auditors may still want a vendor name
```

**The honest answer**: It depends on your scale and risk tolerance.

```
  Scenario                           Best Choice
  ────────                           ───────────
  Startup, 1 cluster, no compliance  OKD + AI + 1 good engineer
  Mid-size, 3-5 clusters, some       OCP subscription (cheaper than
    compliance needs                    hiring a dedicated team)
  Enterprise, 10+ clusters,          OCP subscription + internal team
    strict compliance (finance,         (subscription for binaries/SLA,
    healthcare, government)             team for custom automation)
```

The subscription is really **insurance**. Just like you *could* fix your
own car engine, but when your company's delivery truck breaks down on a
Monday morning, you want a mechanic with a guaranteed response time.

**"Can I package OKD and sell it to customers myself?"**

Legally, yes — OKD is open source (Apache 2.0). You can build, rebrand,
and sell support for it. But consider what you'd be competing against:

```
  Your OKD Business                   Red Hat OpenShift
  ────────────────                    ──────────────────
  Team: 5-10 engineers                Team: 200+ engineers
  Testing: your 3 clusters            Testing: thousands of configs
  Hardware lab: none                  Hardware lab: NVIDIA, AMD, Intel,
                                        IBM Power, ARM, every major
                                        server vendor
  CVE response: "we'll get to it"     CVE response: dedicated security
                                        team, SLA-backed patch times
  Partner ecosystem: you build it     Partner ecosystem: NVIDIA, AWS,
                                        Azure, GCP, VMware, hundreds
                                        of ISVs already certified
  Compliance certs: you pay for       Compliance certs: FIPS 140-2,
    audits yourself                     Common Criteria, FedRAMP,
                                        HIPAA, PCI-DSS — already done
  Brand trust: "who are you?"         Brand trust: Fortune 500 companies
                                        already run Red Hat
  Sales: you cold-call customers      Sales: Red Hat is already in
                                        every enterprise IT department
```

The barrier is not the code — it's **everything around the code**:

```
  What Percentage of Red Hat's Value Is Code vs. Everything Else:

  ┌──────────────────────────────────────────────────────────────┐
  │  Source Code              ██░░░░░░░░░░░░░░░░░░  ~10%         │
  │  Build/Test/Ship pipeline ████░░░░░░░░░░░░░░░░  ~15%         │
  │  Hardware certification   ██████░░░░░░░░░░░░░░  ~15%         │
  │  Security (CVE response)  ██████░░░░░░░░░░░░░░  ~15%         │
  │  Support engineering      ████████░░░░░░░░░░░░  ~20%         │
  │  Partner ecosystem        ██████░░░░░░░░░░░░░░  ~15%         │
  │  Compliance/legal         ████░░░░░░░░░░░░░░░░  ~10%         │
  └──────────────────────────────────────────────────────────────┘
  The open-source code is ~10% of the total value.
```

**Companies that DO sell Kubernetes distributions:**

```
  Company         Product             Strategy
  ───────         ───────             ────────
  Red Hat         OpenShift (OCP)     Full platform + support
  SUSE            Rancher             Multi-cluster management focus
  Canonical       Charmed K8s         Ubuntu ecosystem integration
  VMware/Broadcom Tanzu               vSphere integration focus
  AWS             EKS                 Managed K8s (cloud-only)
  Google          GKE                 Managed K8s (cloud-only)
  Microsoft       AKS                 Managed K8s (cloud-only)

  Notice: every competitor is either a large company with
  thousands of engineers, or a cloud provider who bundles
  K8s with their infrastructure. No 5-person startup
  competes here successfully.
```

**Where a small team CAN win**: Don't compete with Red Hat on the platform
itself — build **on top of** OpenShift/OKD and sell domain-specific value:

```
  Instead of selling "our OKD distribution" (hard):
  ──────────────────────────────────────────────────
  Sell "LLM deployment platform built on OKD"
  Sell "Healthcare compliance automation for OpenShift"
  Sell "GPU cluster management for AI training"
  Sell "OpenShift consulting and migration services"

  You use the free platform, and charge for your
  domain expertise + custom tooling on top of it.
```

This is exactly what many successful small companies do — they don't fight
Red Hat, they ride on OpenShift and add value in a niche Red Hat doesn't
focus on.

**"What about markets where Red Hat pulls out?"**

This question became very real in April 2026, when Red Hat [disbanded its
entire China R&D team](https://www.theregister.com/2026/04/10/red_hat_ends_china_engineering/)
— over 400 engineers, including contributors to OpenShift, libvirt, and QEMU.
VPN access was revoked overnight. The work was relocated to India.

This creates a genuine market gap:

```
  The China Opportunity (post Red Hat exit):
  ──────────────────────────────────────────

  What disappeared:                What remains:
  ─────────────────                ──────────────
  • 400+ Red Hat engineers         • OKD source code (still open)
  • Local Red Hat support          • Huge installed base of
  • Chinese-language engineering     OpenShift clusters in finance,
    resources                        telecom, manufacturing
  • Hardware certification         • 18 years of Red Hat certified
    done locally                     engineers in China (the people,
                                     not the company)
  • Local partner relationships    • Demand for Kubernetes platforms
                                     hasn't decreased
```

**Why this could work with a local team + local partners:**

```
  Advantage of a China-based OKD business:
  ─────────────────────────────────────────

  1. The talent pool just got 400+ experienced OpenShift/K8s
     engineers who need new jobs — they know the codebase

  2. Chinese enterprises already run OpenShift — they need
     continued support, migration paths, and upgrades

  3. Data sovereignty: Chinese companies increasingly prefer
     local vendors for infrastructure (government policy)

  4. Local partners (hardware vendors, cloud providers,
     system integrators) already exist and need a new
     OpenShift-like platform vendor to work with

  5. Compliance: Chinese security standards (等保/MLPS) are
     different from Western ones — a local team understands
     them natively, Red Hat India does not
```

**But the risks are real too:**

```
  Challenge                          Mitigation
  ─────────                          ──────────
  Keeping up with upstream           Hire from the laid-off Red Hat
  OKD/K8s releases                   engineers who WROTE the code

  Building a hardware test lab       Partner with local hardware
  (GPU, server vendors)              vendors (Huawei, Inspur, Sugon)

  Competing with existing Chinese    Differentiate: OKD compatibility
  K8s platforms (KubeSphere,         means existing OpenShift customers
  Rancher, Alibaba ACK)             can migrate without rewriting

  Sustainability — open source       Sell support + consulting + custom
  company revenue is hard            operators, not the platform itself
```

**Existing Chinese Kubernetes landscape to be aware of:**

```
  Platform        Backing           Notes
  ────────        ───────           ─────
  KubeSphere      QingCloud         80,000+ clusters deployed;
                  (Beijing)         pulled open-source edition Aug 2025,
                                    working on free replacement
  Alibaba ACK     Alibaba Cloud     Managed K8s, cloud-only
  Huawei CCE      Huawei Cloud      Managed K8s, cloud-only
  TKE             Tencent Cloud     Managed K8s, cloud-only
  Rancher/SUSE    SUSE (German)     Multi-cluster management,
                                    has China presence
  DaoCloud        DaoCloud          Enterprise K8s platform
                  (Shanghai)        with local support
```

A team that offers **OKD + local support + migration from OpenShift +
Chinese compliance** is filling a gap that literally opened last week.
The 400 laid-off engineers are the talent pool, the existing OpenShift
customers are the market, and the OKD codebase is free.

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

#### Concrete Example: NVIDIA GPU Operator in Action

Let's trace exactly what happens when you install the GPU Operator on a cluster
that has a node with an NVIDIA GPU:

```
  Before GPU Operator                After GPU Operator
  ───────────────────                ──────────────────
  GPU node exists but                GPU is fully usable
  Kubernetes can't see               by pods:
  the GPU:
                                     $ oc describe node gpu-1
  $ oc describe node gpu-1           Allocatable:
  Allocatable:                         cpu: 16
    cpu: 16                            memory: 64Gi
    memory: 64Gi                       nvidia.com/gpu: 1  ← NEW
    (no GPU listed)
```

**Step by step — what the Operator did automatically:**

```
  1. GPU Operator installed via OLM
       │
       ▼
  2. Operator sees NFD labeled node:
     "feature.node.kubernetes.io/pci-10de.present=true"
       │
       ▼
  3. Deploys NVIDIA driver container on that node
     (builds kernel module matching the node's kernel)
       │
       ▼
  4. Deploys nvidia-container-toolkit
     (configures CRI-O to use NVIDIA runtime)
       │
       ▼
  5. Deploys GPU device-plugin pod
     (tells Kubernetes: "this node has 1 nvidia.com/gpu")
       │
       ▼
  6. Deploys GPU Feature Discovery pod
     (labels node with GPU model, memory, driver version)
       │
       ▼
  7. Deploys DCGM Exporter pod
     (sends GPU temperature, utilization, power to Prometheus)
       │
       ▼
  8. Operator keeps watching:
     • New GPU node added?  → repeat steps 3-7
     • Driver needs update? → rolling update, node by node
     • Pod crashed?         → restart it
```

Without the Operator, a human would need to SSH into each GPU node, install
drivers, configure the runtime, deploy the device plugin, and repeat every
time a node is added or a driver update is released. The Operator does all
of this automatically, forever.

#### Concrete Example: Cluster Version Operator (CVO) Upgrade

When Red Hat releases OpenShift 4.16.5, the CVO automates the entire upgrade:

```
  Admin runs: oc adm upgrade --to=4.16.5
       │
       ▼
  CVO downloads new release payload
  (a container image listing all component versions)
       │
       ▼
  CVO reads the payload: "kube-apiserver should be v1.29.3,
  etcd should be v3.5.12, ingress-operator should be v4.16.5..."
       │
       ▼
  CVO updates each component one by one:
       │
       ├── 1. Update etcd (rolling restart, maintain quorum)
       ├── 2. Update kube-apiserver
       ├── 3. Update kube-controller-manager
       ├── 4. Update kube-scheduler
       ├── 5. Update ingress operator
       ├── 6. Update monitoring stack
       ├── 7. ... (dozens more components)
       └── 8. Signal MCO to update RHCOS on each node
              (MCO does cordon → drain → reboot → uncordon)
       │
       ▼
  CVO reports: "Cluster updated to 4.16.5"
  (entire process is automated, no SSH, no manual steps)
```

#### Concrete Example: How You Deploy Your Own App with an Operator

Operators aren't just for platform components — you can use them for your
own applications. For example, the **Prometheus Operator** lets you create
monitoring rules with a YAML file:

```yaml
  # Without Operator: manually edit prometheus.yml,
  # restart Prometheus, hope you didn't break the config.

  # With Operator: declare what you want, Operator handles it.
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: gpu-alerts
  spec:
    groups:
    - name: gpu
      rules:
      - alert: GPUTemperatureTooHigh
        expr: DCGM_FI_DEV_GPU_TEMP > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GPU on {{ $labels.node }} is overheating"
```

```
  What happens when you apply this YAML:

  You: oc apply -f gpu-alerts.yaml
       │
       ▼
  API Server stores the PrometheusRule CR in etcd
       │
       ▼
  Prometheus Operator sees the new CR
       │
       ▼
  Operator generates the correct prometheus.yml config
       │
       ▼
  Operator reloads Prometheus with the new rule
       │
       ▼
  Prometheus now fires an alert if any GPU exceeds 85°C
  for 5 minutes — all without touching Prometheus directly
```

**The pattern is always the same**: you declare *what you want* in a CR,
the Operator figures out *how to make it happen*.

#### Critical OpenShift Operators

| Operator | What It Watches | What It Does When Things Change |
|----------|----------------|--------------------------------|
| **Cluster Version Operator (CVO)** | `ClusterVersion` CR | Downloads new release, updates all cluster components one by one |
| **MachineConfig Operator (MCO)** | `MachineConfig` CR | Rolls out OS-level changes: cordon → drain → apply → reboot → uncordon |
| **Ingress Operator** | `IngressController` CR | Deploys/updates HAProxy routers, manages TLS certificates |
| **NVIDIA GPU Operator** | Nodes with GPU labels | Installs drivers, device plugin, DCGM exporter on each GPU node |
| **OpenShift AI Operator** | `DataScienceCluster` CR | Configures KServe, Knative, Istio, dashboard for model serving |
| **Operator Lifecycle Manager (OLM)** | `Subscription` CR | Installs operators from OperatorHub, handles upgrades |

#### Where Operators Live: OperatorHub

OpenShift includes **OperatorHub** — a catalog of pre-built operators you
can install with one click from the web console:

```
  OperatorHub Categories:
  ───────────────────────

  ┌──────────────────────────────────────────────────────────────────┐
  │  Red Hat Operators   │ Certified Operators │ Community Operators  │
  │  (Red Hat built       │ (partner built,      │ (best-effort,       │
  │   and supported)      │  Red Hat certified)  │  no guarantees)     │
  │                       │                      │                     │
  │  • OpenShift AI       │ • NVIDIA GPU         │ • Prometheus        │
  │  • Service Mesh       │   Operator           │ • Grafana           │
  │  • Serverless         │ • NVIDIA NFD         │ • Strimzi (Kafka)   │
  │  • Logging (Loki)     │ • Crunchy Postgres   │ • ArgoCD            │
  │  • NFD (Red Hat)      │ • MongoDB            │ • Cert-Manager      │
  │  • Pipelines          │ • Redis Enterprise   │ • MinIO (S3)        │
  └──────────────────────────────────────────────────────────────────┘

  Who publishes what:
  • Red Hat Operators    — built by Red Hat, included with subscription
  • Certified Operators  — built by partners (NVIDIA, MongoDB, etc.),
                           tested and certified to work on OpenShift
  • Community Operators  — open-source, community-maintained, no SLA

  Install flow:
  OperatorHub → Click "Install" → OLM creates Subscription CR
  → OLM downloads and deploys the Operator → Operator starts
  watching for its CRs
```

#### How Operators Are Built

You don't write an Operator from scratch — the [Operator SDK](https://sdk.operatorframework.io/)
scaffolds the boilerplate so you only write the business logic.

**Three ways to build an Operator (easiest → most powerful):**

```
  ┌─────────────────────────────────────────────────────────────────┐
  │                  Operator SDK Options                            │
  │                                                                  │
  │  Helm-based            Ansible-based          Go-based           │
  │  ──────────            ─────────────          ────────           │
  │  Wrap an existing      Write Ansible          Write Go code      │
  │  Helm chart as an      playbooks that         with full access   │
  │  Operator. Zero code.  run on reconcile.      to Kubernetes API. │
  │                                                                  │
  │  Good for:             Good for:              Good for:          │
  │  Simple stateless      Day-2 ops (backup,     Complex stateful   │
  │  app deployment        config, upgrades)      apps (databases,   │
  │                                               GPU operators)     │
  │                                                                  │
  │  Effort: Hours         Effort: Days           Effort: Weeks      │
  │  Capability: Level 1   Capability: Level 1-3  Capability: 1-5    │
  └─────────────────────────────────────────────────────────────────┘
```

**Walkthrough: build a simple Go-based Operator**

```bash
# Step 1: Scaffold the project
operator-sdk init --domain example.com \
  --repo github.com/you/my-operator

# Step 2: Create a Custom Resource + Controller
operator-sdk create api \
  --group app --version v1 --kind MyApp \
  --resource --controller
```

This generates two key files:

```
  my-operator/
  ├── api/v1/myapp_types.go              ← Define your CR fields
  └── controllers/myapp_controller.go    ← Write your reconcile logic
```

**File 1: Define the Custom Resource** (`api/v1/myapp_types.go`)

This is where you define *what the user can ask for*:

```go
type MyAppSpec struct {
    // How many replicas the user wants
    Replicas int32  `json:"replicas"`
    // Which container image to run
    Image    string `json:"image"`
}

type MyAppStatus struct {
    // How many replicas are actually running
    ReadyReplicas int32 `json:"readyReplicas"`
}
```

This lets users write YAML like:

```yaml
apiVersion: app.example.com/v1
kind: MyApp
metadata:
  name: hello
spec:
  replicas: 3
  image: nginx:latest
```

**File 2: The Reconcile Loop** (`controllers/myapp_controller.go`)

This is where you write the Watch → Compare → Act logic:

```go
func (r *MyAppReconciler) Reconcile(
    ctx context.Context, req ctrl.Request,
) (ctrl.Result, error) {

    // ── WATCH: fetch the CR from etcd ──
    var app appv1.MyApp
    if err := r.Get(ctx, req.NamespacedName, &app); err != nil {
        return ctrl.Result{}, err
    }

    // ── COMPARE: does a Deployment exist? ──
    var deploy appsv1.Deployment
    err := r.Get(ctx, req.NamespacedName, &deploy)

    if err != nil {
        // Deployment doesn't exist yet → create it
        deploy = buildDeployment(app)   // helper function
        r.Create(ctx, &deploy)          // ── ACT: create ──
        return ctrl.Result{}, nil
    }

    // Deployment exists — is replica count correct?
    if *deploy.Spec.Replicas != app.Spec.Replicas {
        deploy.Spec.Replicas = &app.Spec.Replicas
        r.Update(ctx, &deploy)          // ── ACT: update ──
    }

    // Update status
    app.Status.ReadyReplicas = deploy.Status.ReadyReplicas
    r.Status().Update(ctx, &app)

    return ctrl.Result{}, nil
}
```

```
  What this code does:
  ────────────────────

  User applies:  MyApp { replicas: 3, image: "nginx" }
       │
       ▼
  Reconcile() runs:
       │
       ├── Does a Deployment exist for this MyApp?
       │     No  → Create a Deployment with 3 nginx replicas
       │     Yes → Is replicas == 3?
       │              No  → Update Deployment to 3 replicas
       │              Yes → Do nothing (already in sync)
       │
       ▼
  Update MyApp.status.readyReplicas from Deployment status
       │
       ▼
  Return (Kubernetes calls Reconcile again on any change)
```

**Operator Capability Levels:**

```
  Level 1: Basic Install           "Deploy my app"
  Level 2: Seamless Upgrades       "Upgrade v1 → v2 without downtime"
  Level 3: Full Lifecycle           "Backup, restore, failure recovery"
  Level 4: Deep Insights            "Custom metrics, alerts, dashboards"
  Level 5: Auto Pilot               "Self-tuning, auto-scale, auto-heal"

  Helm Operator    ──── Level 1
  Ansible Operator ──── Level 1-3
  Go Operator      ──── Level 1-5 (GPU Operator, CVO are Level 5)
```

### 6.5 Networking

OpenShift networking has several layers, each solving a different problem.

#### The Big Picture: Three Types of Traffic

```
  ┌──────────────────────────────────────────────────────────────┐
  │                     Traffic Types                             │
  │                                                               │
  │  1. Pod-to-Pod (East-West)                                    │
  │     ┌──────┐  overlay network  ┌──────┐                       │
  │     │Pod A │◄─────────────────►│Pod B │                       │
  │     └──────┘   (OVN-Kubernetes)└──────┘                       │
  │     Even across different nodes — pods talk directly.          │
  │                                                               │
  │  2. External-to-Pod (North-South)                             │
  │     Internet ──► Route ──► Service ──► Pod                    │
  │     Users access your app from outside the cluster.            │
  │                                                               │
  │  3. Pod-to-External                                           │
  │     Pod ──► Service ──► Egress ──► External API               │
  │     Your app calls an external database or API.                │
  └──────────────────────────────────────────────────────────────┘
```

#### Layer 1: Pod Network (OVN-Kubernetes)

Every pod gets its own IP address. Pods can talk to any other pod in the
cluster directly by IP — even across nodes. This "flat network" is created
by **OVN-Kubernetes**, the default network plugin since OpenShift 4.12.

```
  How OVN-Kubernetes creates the pod network:
  ────────────────────────────────────────────

  Node 1 (10.128.0.0/24)            Node 2 (10.128.1.0/24)
  ┌─────────────────────┐           ┌─────────────────────┐
  │  Pod A: 10.128.0.5   │           │  Pod C: 10.128.1.8   │
  │  Pod B: 10.128.0.12  │           │  Pod D: 10.128.1.15  │
  │          │            │           │          │            │
  │          ▼            │           │          ▼            │
  │  ┌──────────────┐    │           │  ┌──────────────┐    │
  │  │ Open vSwitch  │    │           │  │ Open vSwitch  │    │
  │  │ (OVS bridge)  │    │           │  │ (OVS bridge)  │    │
  │  └──────┬───────┘    │           │  └──────┬───────┘    │
  └─────────┼────────────┘           └─────────┼────────────┘
            │                                   │
            └──── Geneve tunnel ────────────────┘
                 (encapsulates pod traffic
                  across the physical network)
```

**Key concepts:**
- Each node gets a subnet (e.g., 10.128.0.0/24) from the cluster CIDR
- OVN assigns each pod an IP from the node's subnet
- **Geneve tunnels** encapsulate pod traffic between nodes — the physical
  network only sees node-to-node traffic, not pod-to-pod
- **Open vSwitch (OVS)** on each node does the actual packet forwarding
  using OpenFlow rules programmed by OVN

```
  Why Geneve instead of VXLAN?
  ────────────────────────────
  OpenShift 3.x used VXLAN (via OpenShift SDN).
  OpenShift 4.12+ uses Geneve (via OVN-Kubernetes).

  Geneve advantages:
  • Variable-length headers → can carry more metadata
  • Better hardware offload support
  • Supports IPv6, dual-stack, and network policies natively
  • Required for advanced features like EgressIP and hybrid networking
```

#### Layer 2: Services (Stable Endpoints)

Pods are ephemeral — they come and go, their IPs change. A **Service** gives
a group of pods a stable IP address and DNS name:

```
  Without Service:                   With Service:
  ────────────────                   ─────────────
  Client must know pod IPs:          Client uses one stable address:
  10.128.0.5 (might die)
  10.128.0.12 (might move)           web-svc.my-app.svc:8080
  10.128.1.8 (might scale away)          │
                                         ▼
  Client must track changes          ┌──────────────┐
  and load-balance itself.           │   Service     │
                                     │  (ClusterIP)  │
                                     │ 172.30.45.67  │
                                     └──────┬───────┘
                                            │ round-robin
                                     ┌──────┼──────┐
                                     ▼      ▼      ▼
                                   Pod A  Pod B  Pod C
```

**Service types:**

```
  Type          Scope              How It Works
  ────          ─────              ────────────
  ClusterIP     Inside cluster     Virtual IP, only reachable from pods
                only               (default)

  NodePort      Outside cluster    Opens a port (30000-32767) on every
                (basic)            node — external clients hit
                                   <nodeIP>:<nodePort>

  LoadBalancer  Outside cluster    Provisions a cloud load balancer
                (cloud)            (AWS ELB, GCP LB, etc.)
                                   that routes to NodePort

  In OpenShift, you rarely use NodePort or LoadBalancer directly.
  Instead, you use Routes (see below).
```

#### Layer 3: Routes (OpenShift's Ingress)

A **Route** exposes a Service to the internet with a hostname and TLS.
Routes are an OpenShift concept — vanilla Kubernetes uses Ingress instead.

```
  How a Route works:
  ──────────────────

  User: curl https://myapp.apps.cluster.example.com
       │
       ▼
  DNS resolves *.apps.cluster.example.com
  → Load Balancer IP (or node IP)
       │
       ▼
  ┌───────────────────────────────────────────────┐
  │  HAProxy Router Pod (runs on infra/worker node)│
  │                                                │
  │  Listens on port 80 and 443                    │
  │  Reads the Host header to decide routing:      │
  │                                                │
  │  "myapp.apps.cluster.example.com"              │
  │       │                                        │
  │       │  matches Route "myapp"                 │
  │       │  in namespace "my-project"             │
  │       ▼                                        │
  │  Forward to Service "myapp-svc"                │
  │       │                                        │
  │       ▼                                        │
  │  Service load-balances to Pods                 │
  └───────────────────────────────────────────────┘
```

**Route TLS options:**

```
  TLS Mode              What It Does
  ────────              ────────────
  Edge                  Router terminates TLS, talks plain HTTP to pod
                        (most common — router handles certs for you)

  Passthrough           Router passes TLS directly to pod (pod does TLS)
                        (use when pod needs to see the client cert)

  Re-encrypt            Router terminates TLS, then opens a NEW TLS
                        connection to pod (encrypted end-to-end,
                        but router can inspect traffic)
```

**Route vs Ingress:**

```
  OpenShift Route                     Kubernetes Ingress
  ───────────────                     ──────────────────
  oc expose svc/web                   Create Ingress YAML
  Automatic TLS termination           Need cert-manager or similar
  Supports passthrough + re-encrypt   HTTP/HTTPS only (basic)
  HAProxy-based (built-in)            Needs an Ingress Controller
                                      (nginx, traefik, etc.)
  OpenShift-specific resource         Standard K8s resource

  In OpenShift, Ingress resources are automatically converted
  to Routes by the Ingress Operator — so both work.
```

#### Layer 4: Network Policies (Pod-to-Pod Firewall)

By default, all pods can talk to all other pods. **NetworkPolicy** lets you
restrict this:

```
  Example: Only allow web pods to talk to the database:
  ─────────────────────────────────────────────────────

  Without NetworkPolicy:           With NetworkPolicy:

  ┌─────┐    ┌─────┐              ┌─────┐    ┌─────┐
  │ web  │───►│ db   │              │ web  │───►│ db   │
  └─────┘    └─────┘              └─────┘    └─────┘
  ┌─────┐    │                    ┌─────┐    │
  │ hack │───►│ (anyone can       │ hack │──✗──│ (blocked by
  └─────┘    │  reach the db)    └─────┘    │  NetworkPolicy)
```

```yaml
# Allow only pods with label "app: web" to reach the db
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-web-only
spec:
  podSelector:
    matchLabels:
      app: db
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: web
      ports:
        - port: 5432
```

#### Layer 5: DNS (CoreDNS)

Every Service automatically gets a DNS name inside the cluster:

```
  DNS naming pattern:
  ───────────────────

  <service-name>.<namespace>.svc.cluster.local

  Examples:
  web.my-app.svc.cluster.local          → Service "web" in "my-app"
  llama3-8b.ai-project.svc.cluster.local → LLM service in "ai-project"
  kubernetes.default.svc.cluster.local   → The API server itself

  Short names also work within the same namespace:
  curl http://web:8080      (from any pod in "my-app" namespace)
```

#### Putting It All Together: Full Network Path

```
  External user → your LLM inference API:
  ────────────────────────────────────────

  curl https://llama3.apps.cluster.example.com/v1/chat/completions
       │
       ▼
  ① DNS: *.apps.cluster.example.com → Load Balancer IP
       │
       ▼
  ② Load Balancer → HAProxy Router (port 443)
       │
       ▼
  ③ Router: TLS termination, reads Host header,
     matches Route "llama3" in namespace "ai-project"
       │
       ▼
  ④ Service "llama3-svc" (ClusterIP 172.30.x.x)
     round-robins to healthy pods
       │
       ▼
  ⑤ OVN-Kubernetes routes packet to correct node
     via Geneve tunnel if pod is on a different node
       │
       ▼
  ⑥ OVS on target node delivers packet to pod's
     network namespace (veth pair)
       │
       ▼
  ⑦ vLLM pod receives request, generates response
       │
       ▼
  ⑧ Response travels back: Pod → OVS → Geneve → Router → User
```

#### CRC Networking (Local Development)

On CRC, networking is simplified — everything runs in one VM:

```
  CRC Host Machine
  ┌──────────────────────────────────────────────┐
  │                                               │
  │  NetworkManager configures DNS:               │
  │  *.apps-crc.testing → CRC VM IP              │
  │  api.crc.testing    → CRC VM IP              │
  │                                               │
  │  ┌─────────────────────────────────┐          │
  │  │  CRC VM (single node)           │          │
  │  │                                  │          │
  │  │  HAProxy Router (:80, :443)      │          │
  │  │       │                          │          │
  │  │       ▼                          │          │
  │  │  Services → Pods                 │          │
  │  │                                  │          │
  │  │  API Server (:6443)              │          │
  │  └─────────────────────────────────┘          │
  │                                               │
  │  To access from host:                          │
  │  curl http://myapp.apps-crc.testing            │
  │                                               │
  │  To access from other machines:                │
  │  Need port forwarding (see Section 15)         │
  └──────────────────────────────────────────────┘
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

### 6.8 CLI Tools: How You Talk to the Cluster

OpenShift provides several command-line tools. Here are the main executables:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                    OKD / OpenShift CLI Tools                      │
  │                                                                   │
  │  Tool               Audience         What It Does                 │
  │  ────               ────────         ────────────                 │
  │                                                                   │
  │  oc                 Everyone         Primary CLI. Superset of     │
  │                                      kubectl — does everything    │
  │                                      kubectl does PLUS OpenShift- │
  │                                      specific commands (routes,   │
  │                                      builds, image streams)       │
  │                                                                   │
  │  kubectl            K8s users        Standard Kubernetes CLI.     │
  │                                      Works, but doesn't know      │
  │                                      OpenShift-specific resources.│
  │                                      Bundled together with oc.    │
  │                                                                   │
  │  crc                Developers       Runs a local single-node     │
  │                                      OpenShift/OKD cluster in a   │
  │                                      VM on your laptop.           │
  │                                                                   │
  │  openshift-install  Cluster admins   Deploys full production      │
  │                                      clusters on AWS, GCP, Azure, │
  │                                      bare metal. Generates        │
  │                                      Ignition configs, creates    │
  │                                      infrastructure, bootstraps.  │
  │                                                                   │
  │  odo (deprecated)   Developers       Developer-focused rapid      │
  │                                      iteration CLI. Being replaced│
  │                                      by oc + devfile workflows.   │
  └──────────────────────────────────────────────────────────────────┘
```

#### `oc` vs `kubectl` — What's the Difference?

`oc` is a **superset** of `kubectl`. When you install `oc`, you get all
`kubectl` commands plus OpenShift-specific ones:

```
  oc-only commands (not in kubectl):
  ──────────────────────────────────

  oc login              Log in with OAuth (kubectl uses kubeconfig only)
  oc new-project        Create a project (namespace + RBAC in one step)
  oc new-app            Create app from source code, Dockerfile, or image
  oc start-build        Trigger a BuildConfig
  oc expose             Create a Route to expose a service externally
  oc adm upgrade        Upgrade the entire cluster
  oc adm top images     Show image storage usage
  oc debug node/X       Open a debug shell on a node (no SSH needed)
  oc whoami             Show current user / token
  oc projects           List all projects you have access to

  Commands that work in BOTH oc and kubectl:
  ──────────────────────────────────────────
  get, describe, apply, delete, logs, exec, port-forward,
  create, edit, patch, scale, rollout, label, annotate...
```

#### Everyday `oc` Cheat Sheet

```bash
# ── Authentication ──
oc login https://api.crc.testing:6443 -u developer -p developer
oc whoami                        # who am I?
oc projects                      # list my projects

# ── Create and deploy an app ──
oc new-project my-app            # create a project (namespace)
oc new-app nginx --name=web      # deploy nginx
oc expose svc/web                # create a Route (external URL)
oc get routes                    # show the URL

# ── Debugging ──
oc get pods                      # list pods
oc logs pod/web-xyz              # view logs
oc exec -it pod/web-xyz -- bash  # shell into a pod
oc debug node/worker-1           # shell on a node (no SSH!)
oc describe pod/web-xyz          # detailed pod info

# ── Cluster admin ──
oc adm upgrade                   # check/apply cluster upgrades
oc get nodes                     # list all nodes
oc describe node worker-1        # node details (CPU, GPU, memory)
oc adm top nodes                 # live CPU/memory usage per node
oc get clusterversion            # current cluster version
```

#### How to Install `oc`

```bash
# Method 1: Bundled with CRC (if you use CRC)
eval $(crc oc-env)

# Method 2: Direct download
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.xz
tar xvf openshift-client-linux.tar.xz
sudo install oc kubectl /usr/local/bin/
oc version
```

#### `openshift-install` — Cluster Deployment

This tool is for deploying **full production clusters**, not for local
development (use `crc` for that):

```
  What openshift-install does:
  ────────────────────────────

  $ openshift-install create cluster --dir=my-cluster
       │
       ▼
  1. Reads install-config.yaml
     (platform, region, node count, network CIDR...)
       │
       ▼
  2. Generates Ignition configs for each node
     (bootstrap, control plane, worker)
       │
       ▼
  3. Creates infrastructure (VMs, DNS, load balancers)
     on your chosen platform (AWS, GCP, Azure, bare metal)
       │
       ▼
  4. Boots a bootstrap node that installs the control plane
       │
       ▼
  5. Control plane takes over, bootstrap is removed
       │
       ▼
  6. Workers join the cluster
       │
       ▼
  7. Cluster is ready (~30-45 minutes)

  Supported platforms:
  AWS, GCP, Azure, VMware vSphere, OpenStack, bare metal,
  IBM Cloud, IBM Power, IBM Z, Nutanix
```

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

> **Why can't I just `dnf install crc`?** CRC is not packaged as an RPM
> in any Fedora/RHEL repo. It's distributed as a standalone binary tarball.
> This is because CRC bundles a pre-built VM image (~4 GB) that contains
> a complete RHCOS + OpenShift install — it's not a normal application,
> it's a tool that manages a VM. You can download it directly from the
> OpenShift mirror without browsing the Red Hat console.

**Install on Fedora:**

```bash
# Step 1: Install virtualization dependencies
sudo dnf install -y libvirt NetworkManager qemu-kvm

# Step 2: Download CRC binary directly
#   Method A: Direct download from OpenShift mirror (no login needed)
wget https://mirror.openshift.com/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz

#   Method B: Or download from Red Hat Console (login required,
#   but also gives you the pull secret for the OpenShift preset):
#   https://console.redhat.com/openshift/create/local

# Step 3: Extract and install
tar xvf crc-linux-amd64.tar.xz
mkdir -p ~/.local/bin
install crc-linux-*-amd64/crc ~/.local/bin/crc

# Make sure ~/.local/bin is in PATH
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Verify
crc version
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
