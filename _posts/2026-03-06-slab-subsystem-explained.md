---
title: Linux Kernel SLUB Slab Allocator
category: tech
tags: [linux kernel, mm, memory, slab]
---

title: Linux Kernel SLUB Slab Allocator

* TOC
{:toc}


# Linux Kernel SLUB Slab Allocator - Comprehensive Guide

> Based on Linux 7.0-rc
> The SLUB allocator (mm/slub.c) is the sole slab implementation since 6.8.

---

## Table of Contents

1. [Top View & Architecture](#1-top-view--architecture)
2. [Basic Principle & Design](#2-basic-principle--design)
3. [Core Data Structures](#3-core-data-structures)
4. [API Reference](#4-api-reference)
5. [Allocation Call Graph](#5-allocation-call-graph)
6. [Free Call Graph](#6-free-call-graph)
7. [Cache Creation Call Graph](#7-cache-creation-call-graph)
8. [Knowledge Graph](#8-knowledge-graph)
9. [Slab/Sheaves Change (v6.18-7.0)](#9-slabsheaves-change-v618-70)

---

## 1. Top View & Architecture

### What is the Slab Allocator?

The slab allocator sits between the page allocator (buddy system) and kernel
subsystems that need small, frequently allocated objects. The page allocator
deals in page-sized (4KB+) chunks, but most kernel objects (inodes, dentries,
sk_buffs, task_structs) are much smaller. The slab allocator:

1. **Pre-allocates pages** and divides them into fixed-size object slots
2. **Caches freed objects** for instant reuse (avoiding page allocator overhead)
3. **Provides per-CPU caching** to minimize lock contention on multi-core systems

### Top-Level Architecture Diagram

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                        Kernel Subsystems                           │
 │  (fs, net, block, drivers, ...)                                    │
 │                                                                    │
 │    kmalloc(size, gfp)          kmem_cache_alloc(cache, gfp)        │
 │    kfree(ptr)                  kmem_cache_free(cache, ptr)         │
 └────────────┬───────────────────────────────┬────────────────────────┘
              │                               │
              ▼                               ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │                     SLUB Slab Allocator                           │
 │                     (mm/slub.c)                                   │
 │                                                                   │
 │  ┌─────────── Per-CPU Layer ──────────────────────────────────┐   │
 │  │                                                            │   │
 │  │   CPU 0              CPU 1              CPU N              │   │
 │  │  ┌──────────┐      ┌──────────┐      ┌──────────┐         │   │
 │  │  │ main     │      │ main     │      │ main     │ sheaves  │   │
 │  │  │ sheaf    │      │ sheaf    │      │ sheaf    │ (arrays  │   │
 │  │  │ [obj,...]│      │ [obj,...]│      │ [obj,...]│ of ptrs) │   │
 │  │  │ spare    │      │ spare    │      │ spare    │          │   │
 │  │  │ sheaf    │      │ sheaf    │      │ sheaf    │          │   │
 │  │  └──────────┘      └──────────┘      └──────────┘         │   │
 │  └────────────────────────┬───────────────────────────────────┘   │
 │                           │                                       │
 │  ┌─────────── Per-Node Layer ─────────────────────────────────┐   │
 │  │                                                            │   │
 │  │   Node 0                        Node 1                     │   │
 │  │  ┌────────────────┐           ┌────────────────┐           │   │
 │  │  │ barn           │           │ barn           │           │   │
 │  │  │  full_sheaves  │           │  full_sheaves  │           │   │
 │  │  │  empty_sheaves │           │  empty_sheaves │           │   │
 │  │  ├────────────────┤           ├────────────────┤           │   │
 │  │  │ partial list   │           │ partial list   │           │   │
 │  │  │  [slab]─[slab] │           │  [slab]─[slab] │           │   │
 │  │  └────────────────┘           └────────────────┘           │   │
 │  └────────────────────────┬───────────────────────────────────┘   │
 │                           │                                       │
 └───────────────────────────┼───────────────────────────────────────┘
                             │
                             ▼
 ┌───────────────────────────────────────────────────────────────────┐
 │                    Page Allocator (Buddy System)                  │
 │                    alloc_pages() / free_pages()                   │
 └───────────────────────────────────────────────────────────────────┘
```

### Source File Layout

| File | Role |
|------|------|
| `include/linux/slab.h` | Public API: kmalloc, kmem_cache_alloc, etc. |
| `mm/slab.h` | Internal header: struct kmem_cache, struct slab |
| `mm/slab_common.c` | Common code: cache create/destroy, kmalloc caches |
| `mm/slub.c` | Core SLUB implementation (~9000 lines) |

---

## 2. Basic Principle & Design

### Core Idea: Object Caching in Slabs

A **slab** is one or more contiguous pages divided into equal-sized object slots:

```
  One Slab (e.g., order-0 = 4096 bytes, object_size = 256)
 ┌──────────┬──────────┬──────────┬──────────┬──────────┐
 │  obj 0   │  obj 1   │  obj 2   │  obj 3   │ ...      │
 │ (256 B)  │ (256 B)  │ (256 B)  │ (256 B)  │          │
 │ IN USE   │  FREE    │ IN USE   │  FREE    │          │
 └──────────┴──────────┴──────────┴──────────┴──────────┘
                 │                      │
                 ▼                      ▼
              freelist ─────────────► next free
              (embedded pointer chain)
```

**Free objects** are chained via an embedded freelist pointer within each object
(at a configurable offset). This avoids separate metadata for tracking free
slots.

### Three-Level Caching Hierarchy

The SLUB allocator uses three levels to minimize contention:

```
  Level 1: Per-CPU Sheaves (fastest - no locking on non-RT)
  ─────────────────────────────────────────────────────────
  • Array of cached object pointers per CPU
  • local_trylock protects (just disables preemption on !RT)
  • Alloc = pop from array, Free = push to array
  • Two sheaves: main (active) + spare (backup)

  Level 2: Per-Node Barn (medium - spinlock)
  ───────────────────────────────────────────
  • Pool of full and empty sheaves per NUMA node
  • When CPU's sheaves deplete: swap empty<->full with barn
  • Amortizes the cost of refill/flush operations

  Level 3: Slab Pages on Partial List (slowest - spinlock)
  ─────────────────────────────────────────────────────────
  • Per-node linked list of partially-used slab pages
  • Must take list_lock to add/remove slabs
  • Last resort before calling page allocator
```

### Fast Path vs Slow Path

```
  ALLOCATION FAST PATH (common case):
  ┌──────────┐    local_trylock     ┌────────────────┐
  │ caller   │───────────────────►  │ percpu sheaf   │  O(1)
  │          │  pop object pointer  │ main->objects[] │  no contention
  └──────────┘                      └────────────────┘

  ALLOCATION SLOW PATH (sheaf empty):
  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │  swap    │────►│  barn    │────►│ partial  │────►│  page    │
  │  spare   │     │  replace │     │  list    │     │  alloc   │
  └──────────┘     └──────────┘     └──────────┘     └──────────┘
   try spare        spinlock         spinlock          may sleep
   sheaf first      on barn          on node           (GFP_KERNEL)

  FREE FAST PATH (common case):
  ┌──────────┐    local_trylock     ┌────────────────┐
  │ caller   │───────────────────►  │ percpu sheaf   │  O(1)
  │          │  push object pointer │ main->objects[] │  no contention
  └──────────┘                      └────────────────┘

  FREE SLOW PATH (sheaf full or remote node):
  ┌──────────┐     ┌──────────┐     ┌──────────────────────┐
  │  swap    │────►│  barn    │────►│ __slab_free()         │
  │  spare   │     │  replace │     │ cmpxchg to slab       │
  └──────────┘     └──────────┘     │ freelist (lockless)   │
                                    └──────────────────────┘
```

### Lock Order

```
  0. cpu_hotplug_lock
  1. slab_mutex              (global, for cache create/destroy)
  2a. cpu_sheaves->lock      (local_trylock, per-CPU)
  2b. node->barn->lock       (spinlock, per-NUMA-node)
  2c. node->list_lock        (spinlock, per-NUMA-node)
  3. slab_lock               (bit spinlock, only on some arches)
```

### kmalloc Size Classes

The `kmalloc()` family uses pre-created caches for power-of-2 sizes plus
two intermediate sizes (96 and 192 bytes):

```
  kmalloc-8, kmalloc-16, kmalloc-32, kmalloc-64,
  kmalloc-96, kmalloc-128, kmalloc-192, kmalloc-256,
  kmalloc-512, kmalloc-1k, kmalloc-2k, kmalloc-4k,
  kmalloc-8k, kmalloc-16k, ...

  Types: KMALLOC_NORMAL, KMALLOC_RECLAIM, KMALLOC_CGROUP, KMALLOC_DMA

  Selection: kmalloc_index(size) -> index into kmalloc_caches[type][index]
```

---

## 3. Core Data Structures

### struct kmem_cache (`mm/slab.h:197`)

The central descriptor for a slab cache:

```c
struct kmem_cache {
    struct slub_percpu_sheaves __percpu *cpu_sheaves;  // per-CPU sheaf arrays
    slab_flags_t flags;           // SLAB_KMALLOC, debug flags, etc.
    unsigned long min_partial;    // min partial slabs to keep per node
    unsigned int size;            // object size INCLUDING metadata
    unsigned int object_size;     // object size WITHOUT metadata
    unsigned int offset;          // freelist pointer offset within object
    unsigned int sheaf_capacity;  // max objects per sheaf
    struct kmem_cache_order_objects oo;  // optimal order + objects per slab
    struct kmem_cache_order_objects min; // minimum (fallback) order
    gfp_t allocflags;            // default GFP flags
    void (*ctor)(void *);        // object constructor (optional)
    const char *name;            // cache name (e.g., "kmalloc-256")
    struct list_head list;       // global slab_caches list
    struct kmem_cache_node *node[MAX_NUMNODES];  // per-NUMA-node data
};
```

### struct slab (`mm/slab.h:74`)

Represents one slab page (overlays struct page):

```c
struct slab {
    memdesc_flags_t flags;
    struct kmem_cache *slab_cache;     // back-pointer to owning cache
    struct list_head slab_list;        // on partial/full list
    void *freelist;                    // head of free object chain
    unsigned long counters;            // packed: inuse:16, objects:15, frozen:1
    // On 64-bit: also includes stride field
};
```

### struct slub_percpu_sheaves (`mm/slub.c:420`)

Per-CPU caching layer:

```c
struct slub_percpu_sheaves {
    local_trylock_t lock;        // preempt-disable on !RT, real lock on RT
    struct slab_sheaf *main;     // active sheaf, never NULL when unlocked
    struct slab_sheaf *spare;    // backup sheaf (empty or full), may be NULL
    struct slab_sheaf *rcu_free; // for batching kfree_rcu() operations
};
```

### struct slab_sheaf (`mm/slub.c:404`)

An array of cached object pointers:

```c
struct slab_sheaf {
    union {
        struct rcu_head rcu_head;    // for RCU-delayed freeing
        struct list_head barn_list;  // when stored in barn
        struct {                     // for prefilled sheafs
            unsigned int capacity;
            bool pfmemalloc;
        };
    };
    struct kmem_cache *cache;  // owning cache
    unsigned int size;         // current number of objects
    void *objects[];           // flexible array of object pointers
};
```

### struct node_barn (`mm/slub.c:396`)

Per-NUMA-node pool of sheaves:

```c
struct node_barn {
    spinlock_t lock;
    struct list_head sheaves_full;   // list of full sheaves
    struct list_head sheaves_empty;  // list of empty sheaves
    unsigned int nr_full;
    unsigned int nr_empty;
};
```

### struct kmem_cache_node (`mm/slub.c:430`)

Per-NUMA-node slab management:

```c
struct kmem_cache_node {
    spinlock_t list_lock;        // protects partial/full lists
    unsigned long nr_partial;    // number of partial slabs
    struct list_head partial;    // partially-used slabs
    struct node_barn *barn;      // sheaf pool for this node
};
```

### Data Structure Relationship Diagram

```
                    struct kmem_cache
                   ┌─────────────────────────┐
                   │ cpu_sheaves ─────────────┼──► [per-CPU]
                   │ size, object_size        │     struct slub_percpu_sheaves
                   │ sheaf_capacity           │    ┌──────────────────┐
                   │ oo (order|objects)       │    │ lock             │
                   │ node[0..N] ──────┐      │    │ main ──► sheaf   │
                   └──────────────────┼──────┘    │ spare ─► sheaf   │
                                      │           │ rcu_free─► sheaf │
                                      ▼           └──────────────────┘
                   struct kmem_cache_node               │
                   ┌──────────────────┐                 ▼
                   │ list_lock        │        struct slab_sheaf
                   │ nr_partial       │       ┌──────────────────┐
                   │ partial ─────────┼──┐    │ cache, size      │
                   │ barn ────────┐   │  │    │ objects[0..cap-1]│
                   └──────────────┼───┘  │    │   [ptr, ptr, ...]│
                                  │      │    └──────────────────┘
                                  ▼      │
                   struct node_barn      │
                   ┌────────────────┐    │
                   │ lock           │    │       struct slab
                   │ sheaves_full ──┼─►  │      ┌──────────────┐
                   │ sheaves_empty  │    └─────►│ slab_cache   │
                   │ nr_full        │           │ slab_list    │
                   │ nr_empty       │           │ freelist ──►obj──►obj
                   └────────────────┘           │ inuse/objects│
                                                └──────────────┘
                                                  (overlays struct page)
```

---

## 4. API Reference

### 4.1 Object Allocation

#### `kmalloc(size, gfp)` / `kmalloc_noprof(size, gfp)`
```c
void *kmalloc(size_t size, gfp_t flags);
```
Allocate `size` bytes of kernel memory. For sizes <= `KMALLOC_MAX_CACHE_SIZE`
(typically 8KB), uses a pre-created kmalloc cache. Larger allocations fall
through to the page allocator. Returns NULL on failure.

**Parameters:**
- `size`: number of bytes to allocate
- `flags`: GFP flags (`GFP_KERNEL`, `GFP_ATOMIC`, `GFP_DMA`, etc.)

#### `kzalloc(size, gfp)`
```c
void *kzalloc(size_t size, gfp_t flags);
```
Like `kmalloc()` but zeros the allocated memory. Equivalent to
`kmalloc(size, flags | __GFP_ZERO)`.

#### `kmalloc_array(n, size, gfp)` / `kcalloc(n, size, gfp)`
```c
void *kmalloc_array(size_t n, size_t size, gfp_t flags);
void *kcalloc(size_t n, size_t size, gfp_t flags);
```
Allocate an array of `n` elements of `size` bytes each. Includes overflow
checking on `n * size`. `kcalloc` also zeros the memory.

#### `krealloc(p, new_size, gfp)`
```c
void *krealloc(const void *p, size_t new_size, gfp_t flags);
```
Resize an allocation. May return the same pointer if the current cache's
object size accommodates `new_size`, or allocate new memory and copy.

#### `kmem_cache_alloc(cache, gfp)`
```c
void *kmem_cache_alloc(struct kmem_cache *s, gfp_t gfpflags);
```
Allocate one object from a specific slab cache. This is the primary typed
allocation interface.

**Call chain:** `kmem_cache_alloc` -> `slab_alloc_node` -> `alloc_from_pcs`
(fast) or `__slab_alloc_node` (slow)

#### `kmem_cache_alloc_node(cache, gfp, node)`
```c
void *kmem_cache_alloc_node(struct kmem_cache *s, gfp_t gfpflags, int node);
```
Like `kmem_cache_alloc` but prefer allocating on the specified NUMA `node`.
Pass `NUMA_NO_NODE` for no preference. When a specific node is requested
and it doesn't match the local node, percpu sheaves are bypassed.

### 4.2 Object Freeing

#### `kfree(ptr)`
```c
void kfree(const void *object);
```
Free a kmalloc'd object. Looks up the slab via `virt_to_slab()`, then calls
`slab_free()`. Handles NULL and large kmalloc (page-backed) objects.

#### `kmem_cache_free(cache, ptr)`
```c
void kmem_cache_free(struct kmem_cache *s, void *x);
```
Free an object back to its slab cache. Validates the object belongs to the
specified cache (with `SLAB_FREELIST_HARDENED`).

**Call chain:** `kmem_cache_free` -> `slab_free` -> `free_to_pcs` (fast)
or `__slab_free` (slow)

### 4.3 Bulk Operations

#### `kmem_cache_alloc_bulk(cache, gfp, size, p)`
```c
int kmem_cache_alloc_bulk(struct kmem_cache *s, gfp_t flags,
                          size_t size, void **p);
```
Allocate `size` objects in bulk, storing pointers in array `p`. Returns number
of objects allocated (0 on total failure). Much more efficient than calling
`kmem_cache_alloc` in a loop - amortizes locking and sheaf/slab overhead.

#### `kmem_cache_free_bulk(cache, size, p)`
```c
void kmem_cache_free_bulk(struct kmem_cache *s, size_t size, void **p);
```
Free `size` objects given in array `p`. Batches local objects into sheaves
and handles remote-node objects separately.

### 4.4 Cache Lifecycle

#### `kmem_cache_create(name, size, align, flags, ctor)`
```c
struct kmem_cache *kmem_cache_create(const char *name, unsigned int size,
                                     unsigned int align, slab_flags_t flags,
                                     void (*ctor)(void *));
```
Create a new slab cache. May merge with an existing compatible cache to save
memory. The `ctor` is called on each new object when a fresh slab is allocated.

**Parameters:**
- `name`: cache name visible in `/proc/slabinfo` and sysfs
- `size`: object size in bytes
- `align`: minimum alignment (0 for natural alignment)
- `flags`: `SLAB_HWCACHE_ALIGN`, `SLAB_TYPESAFE_BY_RCU`, `SLAB_ACCOUNT`, etc.
- `ctor`: constructor function or NULL

**Call chain:** `kmem_cache_create` -> `__kmem_cache_create_args` ->
`__kmem_cache_alias` (try merge) or `create_cache` -> `do_kmem_cache_create`
-> `calculate_sizes` + `init_kmem_cache_nodes` + `alloc_kmem_cache_cpus` +
`setup_sheaves`

#### `kmem_cache_create_usercopy(name, size, align, flags, useroffset, usersize, ctor)`
```c
struct kmem_cache *kmem_cache_create_usercopy(const char *name, unsigned int size,
    unsigned int align, slab_flags_t flags,
    unsigned int useroffset, unsigned int usersize, void (*ctor)(void *));
```
Like `kmem_cache_create` but marks a region `[useroffset, useroffset+usersize)`
within each object as safe for user-space copy (hardened usercopy).

#### `kmem_cache_destroy(cache)`
```c
void kmem_cache_destroy(struct kmem_cache *s);
```
Destroy a slab cache. Decrements refcount; when it reaches zero, flushes all
sheaves/barns, frees all slabs back to the page allocator.

#### `kmem_cache_shrink(cache)`
```c
int kmem_cache_shrink(struct kmem_cache *s);
```
Shrink a cache by flushing percpu sheaves, shrinking barns, and releasing
empty slabs from partial lists.

### 4.5 Prefill / Guaranteed Allocation

#### `kmem_cache_prefill_sheaf(cache, gfp, size)`
```c
struct slab_sheaf *kmem_cache_prefill_sheaf(struct kmem_cache *s,
                                            gfp_t gfp, unsigned int size);
```
Pre-allocate a sheaf of `size` objects. Can be used later with
`kmem_cache_alloc_from_sheaf()` for guaranteed allocation (e.g., in
contexts where allocation might fail).

#### `kmem_cache_return_sheaf(cache, sheaf)`
```c
void kmem_cache_return_sheaf(struct kmem_cache *s, struct slab_sheaf *sheaf);
```
Return a prefilled sheaf's unused objects back to the cache.

### 4.6 Utility Functions

| Function | Description |
|----------|-------------|
| `ksize(ptr)` | Returns actual usable size of kmalloc allocation |
| `kmalloc_size_roundup(size)` | Returns size that kmalloc would actually allocate |
| `kmem_cache_size(cache)` | Returns object_size of the cache |
| `kmem_cache_name(cache)` | Returns name string of the cache |

---

## 5. Allocation Call Graph

![Allocation Call Graph](/assets/images/slab_alloc_callgraph.png)

### Allocation Flow Summary

```
kmalloc() / kmem_cache_alloc()
  │
  ├──► slab_pre_alloc_hook()        # might_alloc, failslab check
  │
  ├──► alloc_from_pcs()             # FAST PATH
  │     │
  │     ├── local_trylock(cpu_sheaves->lock)
  │     ├── pop object from main->objects[--size]
  │     │
  │     └── if main empty:
  │           __pcs_replace_empty_main()
  │             ├── try spare sheaf (swap main<->spare)
  │             ├── barn_replace_empty_sheaf() (swap in barn)
  │             ├── refill_sheaf() -> refill_objects() (from slabs)
  │             └── alloc_full_sheaf() (allocate new + fill)
  │
  ├──► __slab_alloc_node()          # SLOW PATH (fallback)
  │     └── ___slab_alloc()
  │           ├── get_from_partial() -> scan node partial list
  │           └── new_slab() -> allocate_slab() -> alloc_pages()
  │
  └──► slab_post_alloc_hook()       # KASAN, memcg, zeroing, kmemleak
```

---

## 6. Free Call Graph

![Free Call Graph](/assets/images/slab_free_callgraph.png)

### Free Flow Summary

```
kfree() / kmem_cache_free()
  │
  ├──► virt_to_slab()               # object -> slab lookup
  ├──► slab_free_hook()             # poison, debug, KASAN
  │
  ├──► free_to_pcs()                # FAST PATH (local node, non-pfmemalloc)
  │     │
  │     ├── local_trylock(cpu_sheaves->lock)
  │     ├── push object to main->objects[size++]
  │     │
  │     └── if main full:
  │           __pcs_replace_full_main()
  │             ├── try spare sheaf (swap main<->spare)
  │             ├── barn_replace_full_sheaf() (swap in barn)
  │             ├── alloc_empty_sheaf() + __pcs_install_empty_sheaf()
  │             ├── sheaf_flush_unused(spare) -> __slab_free() each obj
  │             └── sheaf_flush_main() (flush directly)
  │
  └──► __slab_free()                # SLOW PATH (remote node / fallback)
        │
        ├── cmpxchg loop: update slab->freelist atomically
        ├── if was_full: add_partial(node, slab)
        └── if now_empty && enough_partials: discard_slab() -> free_pages()
```

---

## 7. Cache Creation Call Graph

![Cache Creation Call Graph](/assets/images/slab_create_callgraph.png)

### Creation Flow Summary

```
kmem_cache_create("my_cache", 128, 0, 0, my_ctor)
  │
  └── __kmem_cache_create_args()
        ├── kmem_cache_sanity_check()
        ├── __kmem_cache_alias()       # try to merge with existing cache
        │     └── find_mergeable()     # find compatible cache
        │
        └── create_cache()             # no merge possible
              ├── kmem_cache_zalloc(kmem_cache, GFP_KERNEL)
              └── do_kmem_cache_create()
                    ├── calculate_sizes()
                    │     # determines: size (with metadata), offset (freelist ptr),
                    │     # oo (order|objects per slab), min (fallback order)
                    │
                    ├── init_kmem_cache_nodes()
                    │     └── for each NUMA node:
                    │           alloc kmem_cache_node + node_barn
                    │           init_kmem_cache_node() + barn_init()
                    │
                    ├── alloc_kmem_cache_cpus()
                    │     └── alloc_percpu(slub_percpu_sheaves)
                    │
                    └── setup_sheaves()
                          └── for each CPU:
                                alloc main sheaf (empty)
                          └── for each node:
                                alloc + init barn
```

---

## 8. Knowledge Graph

### Subsystem Relationship Map

```
                         ┌─────────────────────────┐
                         │     Page Allocator       │
                         │   (buddy system)         │
                         │   alloc_pages/free_pages │
                         └────────────┬─────────────┘
                                      │ allocate/free
                                      │ compound pages
                              ┌───────┴───────┐
                              │  struct slab   │
                              │ (= struct page │
                              │  overlay)      │
                              │                │
                              │ freelist──►obj─┼──►obj──►obj──►NULL
                              │ inuse, objects │
                              │ slab_list      │
                              └───────┬────────┘
                                      │ on partial list
                       ┌──────────────┴──────────────┐
                       │  struct kmem_cache_node      │
                       │  (one per NUMA node)         │
                       │                              │
                       │  partial ──► [slab]──[slab]  │
                       │  list_lock (spinlock)        │
                       │  barn ─────────────────┐     │
                       └──────────────┬─────────┼─────┘
                                      │         │
            owns per-node             │         ▼
              ┌───────────────────────┘    ┌──────────────┐
              │                            │ struct       │
              │                            │ node_barn    │
              │                            │              │
              │                            │ sheaves_full │
              │                            │ sheaves_empty│
              ▼                            │ lock         │
    ┌─────────────────────┐                └──────┬───────┘
    │ struct kmem_cache   │                       │
    │ (cache descriptor)  │                       │ swap sheaves
    │                     │                       │
    │ cpu_sheaves ────────┼───────┐               │
    │ node[0..N] ─────────┼───┐   │               │
    │ size, object_size   │   │   │               │
    │ sheaf_capacity      │   │   │               │
    │ oo, min, flags      │   │   │               │
    └─────────────────────┘   │   │               │
                              │   │               │
                              │   ▼               │
                              │  (per NUMA node)  │
                              │                   │
                              ▼                   │
              ┌──────────────────────┐            │
              │ struct               │            │
              │ slub_percpu_sheaves  │            │
              │ (one per CPU)        │            │
              │                      │            │
              │ lock (local_trylock) │            │
              │ main  ──► sheaf ◄────┼── swap ────┘
              │ spare ──► sheaf      │
              │ rcu_free ► sheaf     │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────┐
              │ struct slab_sheaf│
              │                  │
              │ objects[0]  ──► obj_ptr
              │ objects[1]  ──► obj_ptr
              │ ...             │
              │ objects[cap-1]  │
              │ size (current)  │
              └──────────────────┘
```

### Operation-to-Structure Mapping

```
  Operation              Structures Touched         Lock Required
  ─────────              ──────────────────         ─────────────
  alloc (fast)           percpu_sheaves, sheaf      local_trylock
  alloc (barn)           node_barn                  barn->lock
  alloc (partial)        kmem_cache_node, slab      node->list_lock
  alloc (new slab)       (page allocator)           none (GFP)

  free (fast)            percpu_sheaves, sheaf      local_trylock
  free (barn swap)       node_barn                  barn->lock
  free (to slab)         slab                       cmpxchg (lockless)
  free (list mgmt)       kmem_cache_node            node->list_lock

  cache create           kmem_cache, nodes, barns   slab_mutex
  cache destroy          all structures             slab_mutex
  cache shrink           sheaves, barns, partials   barn+node locks
```

---

## 9. Slab/Sheaves Change (v6.18-7.0)

### Motivation & Background

The SLUB allocator historically used a **per-CPU slab** (called `cpu_slab`)
as its fast caching layer. Each CPU had a "current" slab page from which
objects were allocated via a lockless cmpxchg loop on the slab's freelist.

**Problems with the old per-CPU slab approach:**

1. **Complex lockless protocol:** The fast path used `this_cpu_try_cmpxchg128`
   (or `cmpxchg64` on 32-bit) to atomically update both the freelist pointer
   and counters. This required careful ABA-avoidance and special handling on
   architectures without native double-width CAS.

2. **Free path was rarely fast:** When freeing an object, the fast path only
   worked if the object belonged to the *current* CPU's active slab. Since
   objects often outlive the CPU slab they came from, most frees went to the
   slow path, taking the node's `list_lock`.

3. **PREEMPT_RT complications:** The cmpxchg-based fast path required
   disabling preemption in a way that conflicted with RT requirements,
   leading to separate code paths and fallbacks.

4. **Partial slab management:** CPU "partial" slab lists added another layer
   of complexity with frozen/unfrozen slab state transitions.

### What Are Sheaves?

**Sheaves** (introduced in v6.18, mandatory since v7.0) replace the per-CPU
slab mechanism with a simpler **array-based per-CPU cache**:

```
  OLD (per-CPU slab, removed in 7.0):
  ┌─────────────────────────────────┐
  │  cpu_slab                       │
  │  ├── slab page (current)        │
  │  │    └── freelist ──► obj chain│  cmpxchg128 for alloc/free
  │  └── partial list (frozen slabs)│  complex frozen state
  └─────────────────────────────────┘

  NEW (percpu sheaves):
  ┌─────────────────────────────────┐
  │  slub_percpu_sheaves            │
  │  ├── main sheaf                 │
  │  │    └── objects[0,1,...,N]     │  simple array push/pop
  │  ├── spare sheaf                │  backup for swap
  │  └── rcu_free sheaf             │  RCU batching
  └─────────────────────────────────┘
```

The **barn** is a per-NUMA-node pool of pre-filled and empty sheaves that
serves as an intermediate cache between CPUs and the slab pages:

```
  CPU runs out of objects:
    1. Swap main<->spare (if spare has objects)        FREE
    2. Swap empty main with full sheaf from barn       barn->lock
    3. Refill empty sheaf from partial slabs            list_lock
    4. Allocate new sheaf + fill from new slab page    may sleep
```

### Implementation Timeline

| Version | Change |
|---------|--------|
| v6.18 | Sheaves introduced as **opt-in** via `kmem_cache_args.sheaf_capacity` |
| v6.18 | `kfree_rcu()` sheaf batching added |
| v6.18 | Sheaf prefilling for guaranteed allocations |
| v6.19 | Various fixes and cleanups |
| v7.0 | **Sheaves enabled for ALL caches** (except two bootstrap caches) |
| v7.0 | **Per-CPU slab mechanism removed** (~800 lines deleted) |
| v7.0 | `do_slab_free()` fast path removed |
| v7.0 | Sheaf refill optimized from partial list directly |

### Key Commits

```
2d517aa09bbc  slab: add opt-in caching layer of percpu sheaves
ec66e0d59952  slab: add sheaf support for batching kfree_rcu() operations
3c1ea5c5019f  slab: sheaf prefilling for guaranteed allocations
e47c897a2949  slab: add sheaves to most caches
17c38c88294d  slab: remove cpu (partial) slabs usage from allocation paths
bdc9282f7809  slab: remove the do_slab_free() fastpath
ed30c4adfc2b  slab: add optimized sheaf refill from partial list
913ffd3a1bf5  slab: handle kmalloc sheaves bootstrap
```

### Benefits

1. **Simpler fast path:** Alloc = `objects[--size]`, Free = `objects[size++]`.
   No cmpxchg needed for the common case. Just `local_trylock` (which only
   disables preemption on !RT).

2. **Free path is almost always fast:** Since sheaves cache object pointers
   (not tied to a specific slab), freeing any local-node object goes to the
   sheaf fast path. The old approach only had a fast free path if the object
   came from the *current* CPU slab.

3. **~800 lines of code removed:** The frozen slab state machine, CPU partial
   list management, `cmpxchg128/64` fast paths, and PREEMPT_RT workarounds
   were all eliminated.

4. **Better RT compatibility:** `local_trylock` on RT is a proper per-CPU
   lock with known priority inheritance behavior. No more cmpxchg tricks.

5. **Efficient bulk operations:** Sheaves naturally support bulk alloc/free
   since they're already arrays. The barn enables exchanging full sheaves
   of objects in O(1).

6. **RCU batching:** The `rcu_free` sheaf collects `kfree_rcu` objects and
   submits them via `call_rcu` as a batch, reducing RCU callback overhead.

7. **Prefill support:** `kmem_cache_prefill_sheaf()` allows pre-allocating
   objects for use in atomic/restricted contexts where allocation might fail.

### Drawbacks / Trade-offs

1. **Memory overhead:** Each sheaf is a kmalloc'd array (typically 16-32
   object pointers). With main + spare per CPU + barn sheaves per node,
   this adds metadata overhead compared to the old approach which reused
   the slab page's own freelist.

2. **Indirection:** Objects in sheaves are pointers to objects in slab pages.
   The old approach directly used the slab page's embedded freelist, which
   had better cache locality for sequential allocations from the same slab.

3. **No NUMA locality tracking in sheaves:** Sheaves don't track which NUMA
   node their cached objects came from. When a CPU migrates or objects from
   mixed nodes accumulate, the allocator must verify node locality at
   allocation time, potentially rejecting cached objects.

4. **Bootstrap complexity:** The two initial boot caches (`kmem_cache` and
   `kmem_cache_node`) cannot use sheaves during early boot because the sheaf
   allocation itself requires kmalloc. Special bootstrap handling is needed.

5. **Barn lock contention potential:** Under extreme pressure with many CPUs
   on the same NUMA node all exhausting/filling sheaves simultaneously,
   the barn's spinlock could become a bottleneck (though this is rare
   because the barn operation is O(1) list manipulation).

### Performance Impact

From Vlastimil Babka's commit messages and benchmarks:

- **Free path improvement is the biggest win:** In the old design, ~80% of
  frees went to the slow path. With sheaves, the vast majority of local-node
  frees hit the fast path (simple array push).

- **Lock contention reduction:** The node `list_lock` is taken far less
  frequently because sheaves batch many allocations/frees before needing
  to interact with slab pages.

- **Measured as net positive** in kernel build benchmarks, networking
  workloads, and database-like allocation patterns.

