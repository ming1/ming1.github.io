---
title: AI Infrastructure for Large Model Inference
category: tech
tags: [AI, LLM, inference, GPU, vLLM, infrastructure]
---

title: AI Infrastructure for Large Model Inference

* TOC
{:toc}

# Overview

A single LLM inference request — "Summarize this document" — touches every layer of a complex
infrastructure stack. It enters through an API, gets scheduled into a batch, runs through
transformer computations on GPUs, reads and writes a KV cache in high-bandwidth memory, and
may coordinate across multiple GPUs over high-speed interconnects. Understanding this stack
helps debug latency, optimize throughput, and make architecture decisions.

This post walks through the full stack top-to-bottom, from the user-facing API to the storage
layer that loads model weights.

## Full-Stack Block Diagram

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                        USER / CLIENT                            │
 │                  POST /v1/chat/completions                      │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ HTTP / gRPC
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 6: SERVING & API                                         │
 │  Load Balancer → API Server → Tokenizer → Request Queue         │
 │  (Triton, vLLM API Server, TGI)                                 │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ tokenized prompt + generation params
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 5: SCHEDULING & BATCHING                                 │
 │  Scheduler → Batch Assembly → Preemption Manager                │
 │  (Continuous Batching, Orca, In-flight Batching)                │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ batch of sequences
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 4: MODEL EXECUTION ENGINE                                │
 │  Prefill / Decode → Attention (FlashAttention) → FFN → Output   │
 │  (PyTorch, TensorRT, Custom CUDA Kernels)                       │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ GPU kernel launches + KV cache R/W
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 3: MEMORY & KV CACHE                                     │
 │  Block Manager → Page Table → Physical Block Pool                │
 │  (PagedAttention, vLLM Block Manager)                           │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ GPU memory alloc/free
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 2: CLUSTER & NETWORKING                                  │
 │  Tensor Parallel (AllReduce) │ Pipeline Parallel (P2P)          │
 │  (NCCL, Gloo, RDMA)                                            │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ NVLink / InfiniBand / PCIe
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 1: HARDWARE                                              │
 │  GPU SMs → Tensor Cores → HBM → NVLink / PCIe                  │
 │  (A100, H100, B200)                                             │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ DMA / PCIe transfers
                            ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Layer 0: STORAGE & MODEL LOADING                               │
 │  Disk → CPU RAM → GPU HBM                                       │
 │  (safetensors, GGUF, tensorizer)                                │
 └─────────────────────────────────────────────────────────────────┘

 Request flows ↓ downward     Tokens flow ↑ upward (streamed via SSE)
```

---

# Layer 6: Serving & API

## Definition

The serving layer is the **front door** — it accepts user requests over HTTP/gRPC, validates
them, converts text into tokens, queues them for processing, and streams generated tokens
back to the user.

## Key Concepts

### Token Streaming (SSE)

LLM inference generates tokens one at a time. Instead of waiting for the entire response
(which could take seconds), the API server streams each token back to the client using
**Server-Sent Events (SSE)**. This gives the user the familiar "typing" effect.

```
Client                          API Server                    Engine
  │                                │                            │
  │── POST /chat/completions ─────>│                            │
  │                                │── tokenize + enqueue ─────>│
  │                                │                            │
  │<── SSE: data: {"token":"The"} ─│<── token "The" ───────────│
  │<── SSE: data: {"token":" cat"} │<── token " cat" ──────────│
  │<── SSE: data: {"token":" sat"} │<── token " sat" ──────────│
  │<── SSE: data: [DONE] ─────────│<── EOS ────────────────────│
  │                                │                            │
```

### Request Queuing and Load Balancing

The serving layer queues requests when the GPU is busy, load balances across model replicas,
enforces SLOs (e.g., P99 TTFT under 500ms), and health-checks replicas.

### Tokenization

Before the model can process text, it must be converted to **token IDs** — integers that map
to entries in the model's vocabulary. For example, using the Llama tokenizer:

```
Input:  "Hello, how are you?"
Tokens: [15043, 29892, 920, 526, 366, 29973]
         Hello  ,      how  are you  ?
```

Tokenization happens on the CPU and is fast (~microseconds), but it determines the sequence
length which affects all downstream memory and compute decisions.

### Serving Layer Numbers

Typical performance for a vLLM API server on a single A100-80GB serving Llama 3 8B:

| Metric | Value | Notes |
|--------|-------|-------|
| Max concurrent requests | ~244 | Limited by KV cache, 2K context |
| Request throughput | ~30-50 req/sec | Depends on input/output length |
| TTFT (Time to First Token) | 30-100 ms | Depends on prompt length |
| Tokenization latency | ~0.1 ms | CPU-bound, negligible |
| SSE overhead per token | ~0.01 ms | Network overhead, negligible |

## Typical Implementations

| Implementation | Description | Key Feature |
|---------------|-------------|-------------|
| vLLM API Server | OpenAI-compatible REST API | Built-in continuous batching |
| TGI (Text Generation Inference) | HuggingFace's serving solution | Token streaming, multi-model |
| Triton Inference Server | NVIDIA's general model server | Multi-framework, ensemble models |

## Interface Down

The serving layer passes to the scheduler:
- **Token IDs**: the tokenized prompt (list of integers)
- **Generation parameters**: max_tokens, temperature, top_p, stop sequences
- **Request metadata**: request ID, arrival time, priority

---

# Layer 5: Scheduling & Batching

## Definition

The scheduler decides **when** and **how** to group requests for GPU execution. This is one of
the most important layers for throughput — a bad scheduler can waste 50-80% of GPU capacity.

The core problem: GPU is most efficient when processing many sequences in parallel (large
batch), but sequences have different lengths and arrive at different times.

## Key Concepts

### Static Batching vs. Continuous Batching

**Static batching** (the naive approach): collect N requests, process them all together, wait
until the longest one finishes, then start the next batch.

**Continuous batching** (the modern approach): as soon as one sequence finishes, immediately
replace it with a new one from the waiting queue. The batch is always full.

```
 Static Batching                    Continuous Batching
 ──────────────                     ───────────────────

 Time ──────────────────►          Time ──────────────────►

 Batch 1:                          Batch (always running):
 ┌──────────────────┐              ┌──────────────────┐
 │ Seq A (10 tokens)│              │ Seq A (10 tok)   │→ done, replaced by D
 │ Seq B (50 tokens)│██████████    │ Seq B (50 tok)   │████████████████████
 │ Seq C (20 tokens)│████          │ Seq C (20 tok)   │████████→ done → E
 └──────────────────┘              │ Seq D (15 tok)   │   ▲ joins│████████
 │←── all wait for B ──►│         │ Seq E (30 tok)   │         ▲ joins
 │  A,C idle  █████████  │         └──────────────────┘
                                     ↑ no idle slots — GPU always busy
 Batch 2:
 ┌──────────────────┐
 │ Seq D            │
 │ Seq E            │
 └──────────────────┘
```

`Static batching wastes GPU cycles waiting for the longest sequence.`
`Continuous batching keeps the GPU busy by filling empty slots immediately.`

The throughput improvement is dramatic. Concrete example with Llama 3 8B on A100:

| Batching Strategy | Batch Size | Throughput | GPU Utilization |
|-------------------|-----------|------------|-----------------|
| Static (batch=4, wait for longest) | 4 | ~160 tokens/sec | ~15% |
| Static (batch=32) | 32 | ~800 tokens/sec | ~45% |
| Continuous (dynamic) | 32-64 | ~1,500 tokens/sec | ~80% |

Continuous batching achieves **~2-3x higher throughput** than static batching because it
eliminates idle GPU cycles caused by waiting for the longest sequence.

### Preemption

When GPU memory fills up (because the KV cache for running sequences consumes all available
blocks), the scheduler must **preempt** — temporarily evict a sequence's KV cache to make room
for others. Two strategies:

- **Swap**: copy KV cache from GPU to CPU memory, resume later
- **Recompute**: discard the KV cache, re-run prefill when resuming (cheaper if sequence is short)

### Priority Scheduling

The scheduler can prioritize interactive requests over batch jobs, short sequences over long
ones, and paying customers over free-tier users.

## Typical Implementations

| Implementation | Batching Strategy | Key Innovation |
|---------------|-------------------|----------------|
| vLLM Scheduler | Continuous batching | PagedAttention integration |
| Orca (Seoul Nat'l Univ / FriendliAI) | Iteration-level scheduling | First continuous batching paper |
| TRT-LLM | In-flight batching | NVIDIA-optimized kernels |

## Interface Down

The scheduler passes to the model execution engine:
- **Batch of sequences**: token IDs + positions for each active sequence
- **Operation type**: prefill (new prompt) or decode (generate next token)
- **KV cache metadata**: which memory blocks are allocated for each sequence

---

# Layer 4: Model Execution Engine

## Definition

The model execution engine runs the actual **transformer computation** — the matrix
multiplications, attention operations, and nonlinear functions that turn input tokens into
output tokens. This is where the math happens on the GPU.

## Key Concepts

### The Transformer Block

Every modern LLM is a stack of identical transformer blocks (layers). A Llama 3 8B model has
32 of these blocks. Each block does:

```
 Input token embeddings
         │
         ▼
 ┌───────────────┐
 │  Layer Norm   │    ← normalize values (cheap)
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  Self-        │    ← "which tokens should I pay attention to?"
 │  Attention    │    ← reads from KV cache (previous tokens)
 │  (Q, K, V)    │    ← writes to KV cache (current token)
 │               │    ← compute-heavy for prefill, memory-heavy for decode
 └───────┬───────┘
         │ + residual connection (add input back)
         ▼
 ┌───────────────┐
 │  Layer Norm   │
 └───────┬───────┘
         │
         ▼
 ┌───────────────┐
 │  FFN          │    ← two large matrix multiplications
 │  (Feed-       │    ← with activation function (SiLU/GELU)
 │   Forward)    │    ← this is where most parameters live
 └───────┬───────┘
         │ + residual connection
         ▼
 Output (feed into next block)

 Repeat × 32 blocks (for Llama 3 8B)
```

### Prefill vs. Decode: Two Very Different Workloads

LLM inference has two distinct phases:

**Prefill** (processing the prompt):
- Process all prompt tokens **in parallel** (e.g., 1000 tokens at once)
- Compute-bound: GPU math units (tensor cores) are the bottleneck
- Produces the KV cache for all prompt tokens
- Happens once per request
- Latency determines **Time to First Token (TTFT)**

**Decode** (generating output tokens):
- Generate **one token at a time**, sequentially
- Memory-bandwidth-bound: reading model weights from HBM is the bottleneck
- Each step reads the entire model weights (~16GB for 8B model in FP16) but does very little
  math per byte read
- Happens N times (once per output token)
- Latency per step determines **inter-token latency**

```
 Prefill (compute-bound)          Decode (memory-bound)
 ───────────────────────          ────────────────────────

 ┌─ Prompt: 1000 tokens ─┐       ┌─ Generate 1 token ─┐
 │ All processed in       │       │ Read all weights    │
 │ parallel on GPU        │       │ from HBM (16GB)     │
 │                        │       │ Do tiny amount of   │
 │ Tensor cores busy      │       │ math per token      │
 │ HBM bandwidth: OK      │       │                     │
 │                        │       │ HBM bandwidth: busy │
 │ TTFT = this latency    │       │ Tensor cores: idle  │
 └────────────────────────┘       └─────────────────────┘
                                   Repeat × output_length
```

`This is why memory bandwidth (not FLOPS) is the key spec for inference GPUs.`

### FlashAttention

Standard attention computes a full NxN attention matrix in HBM — slow and O(N^2) memory.
**FlashAttention** tiles the computation into blocks that fit in GPU **shared memory** (SRAM),
never materializing the full matrix. Result: **2-4x faster** attention, especially for long
sequences.

### Quantization

Reducing weight precision cuts memory and improves throughput:

| Precision | Bits | Memory (8B model) | Relative Speed |
|-----------|------|-------------------|----------------|
| FP16/BF16 | 16   | ~16 GB            | 1x (baseline)  |
| FP8       | 8    | ~8 GB             | ~1.5-2x        |
| INT4 (GPTQ/AWQ) | 4 | ~4 GB         | ~2-3x          |

## Typical Implementations

| Implementation | Description | Key Feature |
|---------------|-------------|-------------|
| PyTorch (eager mode) | Default, flexible | Easy to debug, slower |
| torch.compile | JIT compilation | Auto kernel fusion |
| TensorRT-LLM | NVIDIA optimized | Max GPU utilization |
| Custom CUDA kernels | Hand-written | FlashAttention, fused ops |

## Interface Down

The execution engine interacts with:
- **KV cache layer**: read past K,V tensors; write new K,V for current token
- **GPU**: launch CUDA kernels on SMs, use tensor cores for matrix math
- **Cluster layer**: AllReduce across GPUs for tensor parallelism

---

# Layer 3: Memory & KV Cache Management

## Definition

This layer manages the most precious resource in LLM inference: **GPU memory (HBM)**. GPU
memory must hold three things simultaneously:

1. **Model weights** — fixed size, loaded once
2. **KV cache** — grows with each token, one per active sequence
3. **Activations** — temporary, used during computation

The KV cache is the most challenging because it is **dynamic** — it grows as tokens are
generated and varies per sequence. Efficient KV cache management directly determines how many
requests the system can handle concurrently.

## Key Concepts

### GPU Memory Budget: A Concrete Example

An NVIDIA A100-80GB serving Llama 3 8B in FP16:

```
 ┌──────────────────────────────────────────┐
 │           A100-80GB HBM                  │
 │                                          │
 │  ┌────────────────────┐  ← 16 GB        │
 │  │   Model Weights    │    (8B params    │
 │  │   (fixed)          │     × 2 bytes)   │
 │  ├────────────────────┤                  │
 │  │                    │  ← ~2 GB         │
 │  │   Activations      │    (temporary    │
 │  │   (workspace)      │     buffers)     │
 │  ├────────────────────┤                  │
 │  │                    │                  │
 │  │                    │  ← ~62 GB        │
 │  │    KV Cache        │    (available    │
 │  │    (dynamic)       │     for caching  │
 │  │                    │     tokens)      │
 │  │                    │                  │
 │  │                    │                  │
 │  └────────────────────┘                  │
 └──────────────────────────────────────────┘
```

### How Big is the KV Cache?

For each token in each sequence, the KV cache stores K and V vectors for every attention head
in every layer:

```
KV cache per token = 2 × num_layers × num_heads × head_dim × bytes_per_element

Llama 3 8B:
  = 2 × 32 layers × 8 KV heads (GQA) × 128 dim × 2 bytes (FP16)
  = 131,072 bytes = 128 KB per token
```

With 62 GB available for KV cache:
- Maximum tokens in cache: 62 GB / 128 KB = ~**500,000 tokens**
- At 2048 tokens per sequence: ~**244 concurrent sequences**
- At 8192 tokens per sequence: ~**61 concurrent sequences**

`The KV cache — not compute — is what limits how many users you can serve simultaneously.`

### PagedAttention: Virtual Memory for KV Cache

The key innovation in vLLM. Traditional systems allocate KV cache as one contiguous block per
sequence, sized for the **maximum possible length**. This wastes memory because:

1. Most sequences don't reach max length — **internal fragmentation**
2. You must reserve max-length blocks upfront — **external fragmentation**
3. Shared prefixes (system prompts) are duplicated — **no sharing**

PagedAttention borrows **OS virtual memory** ideas — non-contiguous physical blocks mapped
via a per-sequence page table, demand-allocated one block at a time:

```
 Traditional (contiguous)              PagedAttention (paged)
 ────────────────────────              ──────────────────────

 ┌───┬───┬───┬───┬───┬───┬───┐       Logical:  [0][1][2][3][4]
 │ A │ A │ A │ A │ A │   │   │                    │  │  │  │  │
 │ 0 │ 1 │ 2 │ 3 │ 4 │ X │ X │       Page tbl:   ▼  ▼  ▼  ▼  ▼
 └───┴───┴───┴───┴───┴───┴───┘       Physical: [7][2][9][4][1]
   contiguous       wasted
                                      Non-contiguous is fine!
 Waste: 2 blocks per sequence         Waste: 0 blocks
```

Benefits: near-zero waste, no fragmentation, **copy-on-write sharing** for common prefixes
(system prompts). Memory utilization improves from ~20-40% to **>95%**.

## Typical Implementations

| Implementation | Approach | Key Feature |
|---------------|----------|-------------|
| vLLM Block Manager | Paged allocation | PagedAttention, CoW sharing |
| TRT-LLM KV Cache | Paged KV cache | NVIDIA-optimized memory pools |
| HuggingFace TGI | Token-level allocation | Simpler but less efficient |

## Interface Down

- **GPU memory APIs**: cudaMalloc/cudaFree for block pools, cudaMemcpy for swap operations
- **DMA engine**: for CPU↔GPU KV cache swap during preemption

---

# Layer 2: Cluster & Networking

## Definition

Large models (70B+ parameters) don't fit in a single GPU's memory. This layer connects
multiple GPUs — within a node and across nodes — so they can work together on a single model.

For example, Llama 3 70B in FP16 needs ~140 GB for weights alone. A single A100-80GB cannot
hold it. You need at least 2 GPUs (with tensor parallelism).

## Key Concepts

### Three Types of Parallelism

```
 Tensor Parallelism (TP)          Pipeline Parallelism (PP)
 ─────────────────────            ─────────────────────────

 Split each layer ACROSS GPUs     Split layers BETWEEN GPUs

 ┌─────────┐                      ┌─────────┐
 │ Layer 1  │                      │Layers   │ ← GPU 0
 │┌───┬────┐│                      │ 1 - 16  │
 ││GPU│GPU ││                      └────┬────┘
 ││ 0 │ 1  ││ ← each GPU has            │ activations
 │└───┴────┘│   half the layer     ┌────▼────┐
 ├─────────┤│                      │Layers   │ ← GPU 1
 │ Layer 2  │                      │ 17 - 32 │
 │┌───┬────┐│                      └─────────┘
 ││GPU│GPU ││
 ││ 0 │ 1  ││                     Each GPU holds ALL of
 │└───┴────┘│                     its assigned layers.
 └─────────┘│                     Communication: only at
                                   stage boundaries.
 Each GPU holds HALF of
 every layer. Communication:
 AllReduce after every layer.


 Data Parallelism (DP)
 ─────────────────────
 Each GPU has a full model copy, processes different requests.
 Used for scaling throughput, not for fitting larger models.
```

### Communication Patterns

| Parallelism | Communication | Frequency | Bandwidth Need |
|-------------|---------------|-----------|---------------|
| Tensor (TP) | AllReduce | Every layer (80x for 70B) | **Very high** — needs NVLink |
| Pipeline (PP) | Point-to-point | At stage boundaries (1-2x) | Moderate — PCIe OK |
| Data (DP) | None during inference | N/A | N/A |

### NCCL

NCCL is the standard library for multi-GPU communication, automatically selecting the best
transport:

```
 Within a node (fast):              Across nodes (slower):
 ┌────────┐    NVLink    ┌────────┐ ┌────────┐  InfiniBand  ┌────────┐
 │ GPU 0  │◄───900GB/s──►│ GPU 1  │ │ GPU 0  │◄──400Gb/s───►│ GPU 4  │
 │        │              │        │ │ Node 0 │   (RDMA)      │ Node 1 │
 └────────┘              └────────┘ └────────┘              └────────┘
```

### Why Tensor Parallelism Needs NVLink

TP requires an AllReduce after every transformer layer. For Llama 3 70B with TP=4:

```
AllReduce data per layer = 2 × hidden_size × batch_size × bytes
                        = 2 × 8192 × 32 × 2 bytes
                        = 1 MB per layer

Total per token = 1 MB × 80 layers = 80 MB per decode step
At 100 tokens/sec = 8 GB/sec sustained AllReduce bandwidth
```

`Over PCIe (~25 GB/s effective), this consumes ~32% of bandwidth.`
`Over NVLink (900 GB/s), it's <1%. NVLink makes TP nearly free.`

## Typical Implementations

| Technology | Bandwidth | Scope | Use Case |
|-----------|-----------|-------|----------|
| NVLink 4.0 (H100) | 900 GB/s | Intra-node GPU↔GPU | Tensor parallelism |
| NVSwitch | Full bisection | Intra-node all-to-all | Large TP degrees (8-way) |
| InfiniBand NDR | 400 Gb/s (50 GB/s) | Inter-node | Pipeline parallelism, DP |
| RoCE (RDMA over Ethernet) | 100-400 Gb/s | Inter-node | Lower-cost alternative |

## Interface Down

- Hardware interconnects: NVLink (intra-node), InfiniBand/Ethernet (inter-node)
- RDMA for zero-copy transfers; CUDA events/streams for GPU synchronization

---

# Layer 1: Hardware

## Definition

The physical compute, memory, and interconnect substrate. For LLM inference, the GPU is the
central component — specifically its **memory bandwidth**, **compute units (SMs and tensor
cores)**, and **high-bandwidth memory (HBM)**.

## Key Concepts

### GPU Architecture for Inference

A GPU contains many **Streaming Multiprocessors (SMs)**, each with **tensor cores** for matrix
math:

```
 ┌─────────────────────────────────────────────────────┐
 │                    GPU Chip                          │
 │                                                     │
 │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    ... (132 SMs  │
 │  │ SM  │ │ SM  │ │ SM  │ │ SM  │     on H100)      │
 │  │┌───┐│ │┌───┐│ │┌───┐│ │┌───┐│                   │
 │  ││TC ││ ││TC ││ ││TC ││ ││TC ││  ← Tensor Cores   │
 │  │└───┘│ │└───┘│ │└───┘│ │└───┘│    (matrix math)  │
 │  │┌───┐│ │┌───┐│ │┌───┐│ │┌───┐│                   │
 │  ││SRAM│ ││SRAM│ ││SRAM│ ││SRAM│  ← Shared Memory  │
 │  ││    │ ││    │ ││    │ ││    │    (fast, small)   │
 │  │└───┘│ │└───┘│ │└───┘│ │└───┘│                   │
 │  └─────┘ └─────┘ └─────┘ └─────┘                   │
 │                                                     │
 │  ┌─────────────────────────────────────────┐        │
 │  │              L2 Cache (~50 MB)          │        │
 │  └─────────────────────────────────────────┘        │
 │                      │                              │
 │                      ▼                              │
 │  ┌─────────────────────────────────────────┐        │
 │  │        HBM (High Bandwidth Memory)      │        │
 │  │        80 GB capacity (A100)            │        │
 │  │        2 TB/s bandwidth (A100)          │        │
 │  │        3.35 TB/s bandwidth (H100)       │        │
 │  └─────────────────────────────────────────┘        │
 │                                                     │
 │  ┌──────────────┐    ┌──────────────┐               │
 │  │   NVLink     │    │    PCIe      │               │
 │  │  GPU↔GPU     │    │  GPU↔CPU     │               │
 │  │  900 GB/s    │    │  128 GB/s    │               │
 │  └──────────────┘    └──────────────┘               │
 └─────────────────────────────────────────────────────┘
```

### Memory Hierarchy

Speed and size are inversely related — just like CPU caches:

| Level | Size | Bandwidth | Latency | What Lives Here |
|-------|------|-----------|---------|-----------------|
| Registers | ~256 KB/SM | — | 0 cycles | Current computation |
| Shared Memory (SRAM) | ~228 KB/SM | ~19 TB/s | ~20 cycles | FlashAttention tiles |
| L2 Cache | ~50 MB | ~12 TB/s | ~200 cycles | Hot data reuse |
| HBM | 80-192 GB | 2-3.35 TB/s | ~400 cycles | Weights, KV cache |
| CPU RAM (via PCIe) | TBs | 64-128 GB/s | ~10,000 cycles | KV cache swap, overflow |

### GPU Comparison for Inference

| Spec | A100 | H100 | B200 |
|------|------|------|------|
| FP16 TFLOPS | 312 | 989 | ~2,250 |
| HBM Capacity | 80 GB | 80 GB | 192 GB |
| HBM Bandwidth | 2.0 TB/s | 3.35 TB/s | 8.0 TB/s |
| NVLink Bandwidth | 600 GB/s | 900 GB/s | 1,800 GB/s |
| TDP | 400W (SXM) | 700W | 1000W |

### Why Memory Bandwidth Matters More Than FLOPS

During decode, the GPU reads the entire model weights for every single output token but does
very little math per byte:

```
Arithmetic intensity = FLOPS / Bytes read

Decode (batch_size=1):
  FLOPS per token ≈ 2 × params = 2 × 8B = 16 GFLOPS
  Bytes read      ≈ params × 2 = 8B × 2  = 16 GB

  Arithmetic intensity = 16 GFLOPS / 16 GB = 1 FLOP/byte
```

At 1 FLOP/byte, the H100 can only do 3.35 TFLOPS of useful work — **0.3% of peak compute**.

`For single-request decode, you pay for 989 TFLOPS but use 3.35. Batching fixes this.`

Weights are read once but used for all sequences in the batch:

| Batch Size | Arithmetic Intensity | H100 Utilization |
|-----------|---------------------|-----------------|
| 1 | 1 FLOP/byte | 0.3% |
| 8 | 8 FLOP/byte | 2.7% |
| 64 | 64 FLOP/byte | 21% |
| 256 | 256 FLOP/byte | 85% |

## Interface Down

- **PCIe Gen5 x16**: connects GPU to CPU and NVMe storage (64 GB/s per direction, 128 GB/s bidirectional)
- **Power delivery**: 400W (A100 SXM) to 1000W (B200) per GPU — cooling and power infrastructure
  are physical constraints on cluster density
- **Physical form factor**: SXM (high-end, NVLink-capable) vs. PCIe (standard server slots)

---

# Layer 0: Storage & Model Loading

## Definition

Before inference can begin, model weights must travel from persistent storage (SSD/network)
through CPU memory and into GPU HBM. This "cold start" can take seconds to minutes depending
on model size and storage performance.

## Key Concepts

### The Loading Pipeline

```
 ┌─────────┐  read   ┌──────────┐  DMA    ┌──────────┐
 │  NVMe   │────────►│ CPU RAM  │────────►│ GPU HBM  │
 │  SSD    │ 7 GB/s  │          │ 32 GB/s │          │
 │         │ (PCIe5) │ (DDR5)   │ (PCIe5) │          │
 └─────────┘         └──────────┘         └──────────┘

 Llama 3 8B (FP16 = 16GB):
   SSD → CPU:  16GB / 7GB/s  = 2.3 seconds
   CPU → GPU:  16GB / 32GB/s = 0.5 seconds
   Total cold start: ~2.8 seconds

 Llama 3 70B (FP16 = 140GB):
   SSD → CPU:  140GB / 7GB/s  = 20 seconds
   CPU → GPU:  140GB / 32GB/s = 4.4 seconds (across 2 GPUs)
   Total cold start: ~25 seconds
```

### Checkpoint Formats

| Format | Description | Key Feature |
|--------|-------------|-------------|
| safetensors | HuggingFace standard | Memory-mapped, zero-copy loading, safe (no pickle) |
| GGUF | llama.cpp format | Quantized models, single-file, metadata included |
| PyTorch .bin | Legacy pickle-based | Flexible but slow, security risk (arbitrary code exec) |
| TensorRT engines | NVIDIA compiled | GPU-specific, pre-optimized, fast loading |

### Optimizing Load Time

1. **Memory-mapped I/O** (safetensors): map the file into address space, let the OS page in data
2. **Tensor parallelism sharding**: pre-shard so each GPU loads 1/N in parallel
3. **Model caching**: keep models in CPU RAM or RAM disk, eliminating the SSD read
4. **GPUDirect Storage**: DMA from NVMe directly to GPU HBM, bypassing CPU entirely

`For large models, cold start can take 30+ seconds. In autoscaling scenarios, this directly`
`impacts how quickly new replicas can serve traffic. Storage performance matters.`

## Interface Down

- **Storage I/O**: NVMe read operations (this is where kernel-bypass like SPDK can help)
- **CPU→GPU transfer**: cudaMemcpy or CUDA unified memory
- **GPUDirect Storage**: cuFile API for direct NVMe→GPU DMA

---

# Deep Dive: vLLM — Putting It All Together

## What Problem Does vLLM Solve?

Before vLLM, LLM serving systems wasted **60-80% of GPU memory** on KV cache fragmentation —
contiguous allocation for max-length sequences, no reclamation until completion, and duplicated
shared prefixes. vLLM introduced **PagedAttention** and achieved **2-4x higher throughput** than
HuggingFace TGI at the time of release.

## vLLM Architecture

```
 ┌──────────────────────────────────────────────────────────┐
 │                     vLLM Server                          │
 │                                                          │
 │  ┌──────────┐    ┌───────────┐    ┌──────────────────┐  │
 │  │ API      │───►│ Tokenizer │───►│ Scheduler        │  │
 │  │ Server   │    │           │    │ ┌──────────────┐ │  │
 │  │ (FastAPI)│    │ (HF       │    │ │Waiting Queue │ │  │
 │  │          │    │ Tokenizers│    │ ├──────────────┤ │  │
 │  │ OpenAI-  │    │ library)  │    │ │Running Batch │ │  │
 │  │ compat   │    │           │    │ ├──────────────┤ │  │
 │  │ REST API │    │           │    │ │Swapped Queue │ │  │
 │  └──────────┘    └───────────┘    │ └──────────────┘ │  │
 │                                   └────────┬─────────┘  │
 │                                            │            │
 │  ┌─────────────────────────────────────────▼─────────┐  │
 │  │              Model Runner                         │  │
 │  │  ┌─────────────┐  ┌──────────────┐               │  │
 │  │  │ Model       │  │ Attention    │               │  │
 │  │  │ (Transformer│  │ Backend     │               │  │
 │  │  │  layers)    │  │ (FlashAttn  │               │  │
 │  │  │             │  │  or xformers)│               │  │
 │  │  └─────────────┘  └──────────────┘               │  │
 │  └───────────────────────┬───────────────────────────┘  │
 │                          │                              │
 │  ┌───────────────────────▼───────────────────────────┐  │
 │  │            Block Manager                          │  │
 │  │  ┌──────────┐  ┌───────────┐  ┌───────────────┐  │  │
 │  │  │Page Table│  │GPU Block  │  │CPU Block      │  │  │
 │  │  │(per seq) │  │Pool       │  │Pool (for swap)│  │  │
 │  │  └──────────┘  └───────────┘  └───────────────┘  │  │
 │  └───────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────┘
```

## Request Lifecycle: Tracing a Single Request

Let's follow a chat completion request through all layers:

```
POST /v1/chat/completions
{
  "model": "meta-llama/Llama-3-8B-Instruct",
  "messages": [{"role": "user", "content": "What is PagedAttention?"}],
  "max_tokens": 256,
  "stream": true
}
```

**Step 1 — Layer 6 (API Server)**: FastAPI server receives the HTTP request, validates
parameters, and passes the message to the tokenizer.

**Step 2 — Layer 6 (Tokenizer)**: HuggingFace tokenizer converts the chat template + message
into token IDs: `[128000, 128006, 9125, ..., 128009]` (about 20 tokens for this short prompt).
Creates a `SequenceGroup` object.

**Step 3 — Layer 5 (Scheduler)**: The sequence group enters the **waiting queue**. On the next
scheduling step (~10ms), the scheduler:
- Checks if there are enough free GPU memory blocks for this sequence
- If yes: moves it to the **running batch** and allocates initial KV cache blocks
- If no: the sequence stays in the waiting queue (or preempts a lower-priority sequence)

**Step 4 — Layer 4 (Prefill)**: Model runner processes all 20 tokens in parallel through 32
layers. KV cache written to GPU. **TTFT: ~50ms** on A100.

**Step 5 — Layer 3 (Block Manager)**: Allocates physical blocks on demand (16 tokens/block).
20-token prompt uses 2 blocks.

**Step 6 — Layer 4 (Decode)**: For each output token: read weights (~16 GB), read KV cache,
compute attention+FFN, sample, write new K,V. **~25ms/token** (batch=1).

**Step 7 — Layer 6 (Streaming)**: Each token is detokenized and sent as SSE event.

**Step 8 — Layer 5 (Completion)**: On EOS or max_tokens, scheduler removes the sequence and
frees its blocks.

## PagedAttention in vLLM

PagedAttention is the core innovation that makes vLLM work. It applies the same idea as
**OS virtual memory paging** to KV cache management:

| OS Virtual Memory | vLLM PagedAttention |
|-------------------|---------------------|
| Process address space | Sequence's KV cache |
| Virtual page | Logical KV block |
| Physical page frame | Physical GPU memory block |
| Page table | Block table (per sequence) |
| Demand paging | Allocate blocks as tokens are generated |
| Copy-on-write | Share prefix blocks between sequences |
| Swap to disk | Swap KV blocks to CPU memory |

When multiple requests share the same **system prompt** (e.g., "You are a helpful assistant..."),
vLLM stores those KV cache blocks only once in GPU memory. Each sequence's block table points
to the same physical blocks for the shared prefix. When a sequence diverges (the user's actual
question), vLLM copies only the diverging block — **copy-on-write**, exactly like `fork()` in
Unix.

For a system prompt of 500 tokens shared by 100 concurrent sequences:
- Without sharing: 500 × 100 × 128 KB = **6.25 GB** wasted on duplicates
- With CoW sharing: 500 × 128 KB = **62.5 MB** — a **100x reduction**

## Continuous Batching in Practice

Here is how vLLM's scheduler handles 3 requests arriving at different times:

```
 Time ──────────────────────────────────────────────►

 t=0ms: Request A arrives (prompt=100 tokens, max_output=50)
 t=5ms: Request B arrives (prompt=200 tokens, max_output=30)
 t=8ms: Request C arrives (prompt=50 tokens, max_output=100)

 Scheduler steps (every ~10ms):

 Step 1 (t=0):  Prefill A  ──────────────────────────
                [A: prefill 100 tokens]

 Step 2 (t=10): Prefill B + Decode A  ───────────────
                [B: prefill 200 tokens][A: decode tok 1]

 Step 3 (t=20): Prefill C + Decode A,B  ─────────────
                [C: prefill 50 tok][A: decode 2][B: decode 1]

 Step 4-15:     Decode A,B,C together  ──────────────
                [A: decode 3..][B: decode 2..][C: decode 1..]

 Step 12 (t=120): B finishes (30 tokens done)
                  → free B's blocks
                  → if Request D is waiting, add D to batch

 Step 16 (t=160): A finishes (50 tokens done)
                  → free A's blocks → add next waiting request

 Step 25 (t=250): C finishes (100 tokens done)
```

Key behaviors:
- **No waiting**: each request is prefilled as soon as GPU has capacity
- **No padding**: finished requests are immediately replaced
- **Preemption**: if a step would exceed GPU memory, the scheduler can **swap** the
  lowest-priority sequence's KV cache to CPU and resume it later

## Concrete Numbers: Llama 3 8B on A100-80GB

| Resource | Size | Notes |
|----------|------|-------|
| Model weights (FP16) | 16 GB | Fixed |
| Activations workspace | ~2 GB | Depends on batch size |
| Available for KV cache | ~62 GB | Main variable |
| KV cache per token | 128 KB | 2 × 32 × 8 × 128 × 2B |
| Block size | 16 tokens = 2 MB | vLLM default |
| Total blocks | ~31,000 | 62 GB / 2 MB |
| Max concurrent sequences (2K ctx) | ~244 | 31000 / (2048/16) |
| Max concurrent sequences (8K ctx) | ~61 | 31000 / (8192/16) |
| Throughput (continuous batching) | ~1,500 tokens/sec | Batch-dependent |
| TTFT (prefill, 128 tokens) | ~30 ms | Compute-bound |
| Inter-token latency (batch=1) | ~25 ms | Memory-bandwidth-bound |
| Inter-token latency (batch=64) | ~35 ms | Better GPU utilization |

`Larger batches increase throughput but also increase per-token latency.`
`Batch=64 yields ~1,800 tokens/sec total vs. 40 tokens/sec for batch=1.`

---

# Summary

## The Full Stack at a Glance

| Layer | What It Does | Key Bottleneck | Key Innovation |
|-------|-------------|----------------|----------------|
| 6: Serving & API | Accept requests, stream tokens | Request queuing | SSE streaming |
| 5: Scheduling | Batch requests efficiently | Sequence length variance | Continuous batching |
| 4: Execution | Run transformer math | Prefill=compute, Decode=memory | FlashAttention |
| 3: Memory & KV Cache | Manage GPU memory | KV cache fragmentation | PagedAttention |
| 2: Cluster | Connect multiple GPUs | Communication overhead | NVLink + NCCL |
| 1: Hardware | Provide compute + memory | HBM bandwidth | Higher-BW HBM generations |
| 0: Storage | Load model weights | Cold start time | Safetensors, GPUDirect |

## Key Takeaways

1. **Memory bandwidth, not FLOPS**, is the primary bottleneck for LLM inference. A single
   decode step reads the entire model from HBM but does very little math per byte.

2. **Continuous batching** transforms inference from a latency-optimized to a
   throughput-optimized workload, keeping GPUs busy instead of waiting for the longest sequence.

3. **PagedAttention** eliminates KV cache memory waste by managing it like OS virtual memory —
   demand-allocated, non-contiguous, and shareable. This alone can 2-4x serving throughput.

4. **The KV cache is the scaling bottleneck** — not model weights, not compute. As context
   lengths grow (128K+ tokens), KV cache management becomes increasingly critical.

5. **NVLink is essential for tensor parallelism** — the AllReduce communication after every
   transformer layer would saturate PCIe bandwidth, but NVLink handles it with <1% overhead.

---

# References

- [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180) — the vLLM paper (SOSP'23)
- [FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness](https://arxiv.org/abs/2205.14135) — FlashAttention paper
- [Orca: A Distributed Serving System for Transformer-Based Generative Models](https://www.usenix.org/conference/osdi22/presentation/yu) — continuous batching (OSDI'22)
- [vLLM GitHub Repository](https://github.com/vllm-project/vllm) — open-source inference engine
- [NVIDIA H100 Tensor Core GPU Architecture](https://resources.nvidia.com/en-us-tensor-core) — H100 whitepaper
