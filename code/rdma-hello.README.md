# rdma-hello — building, running, and the RDMA environment

`rdma-hello.c` is a minimal RDMA SEND/RECV "hello" written with
**libibverbs** only (plus a throwaway TCP socket for the rendezvous; no
librdmacm). Two peers build an RC queue pair, swap QPN/PSN/GID over TCP,
drive the QP through RESET → INIT → RTR → RTS by hand, then each SENDs a
greeting and RECVs the other's. Companion to the blog post
"RDMA from Top to Bottom" (§3 programming model, §4 kernel / RDMA CM) —
this is the raw bring-up that `rdma_cm` normally hides.

Unlike true RDMA hardware demos, this one runs on an **ordinary machine**
via Soft-RoCE.

## 1. Software

- `rdma-core` runtime (`libibverbs`, plus `ibv_devices` / `ibv_devinfo`
  / `rdma` tools) and the **dev headers** to build:
  - Fedora/RHEL: `sudo dnf install rdma-core-devel libibverbs-utils iproute`
  - Debian/Ubuntu: `sudo apt install libibverbs-dev rdma-core ibverbs-utils`
- A kernel with the Soft-RoCE module `rdma_rxe` (mainline since 4.8).

## 2. Set up a software RDMA device (Soft-RoCE)

No RDMA NIC needed. Create an `rxe` device over an existing netdev:

```bash
sudo modprobe rdma_rxe
# bind it to a real NIC for two-host tests:
sudo rdma link add rxe0 type rxe netdev eth0
# ...or to loopback for a single-box test:
sudo rdma link add rxe0 type rxe netdev lo

rdma link            # expect: link rxe0/1 state ACTIVE physical_state LINK_UP
ibv_devices          # expect rxe0 in the list
```

(SoftiWARP works too: `modprobe siw` and `rdma link add siw0 type siw
netdev eth0`.)

## 3. Find the GID index

RoCE addresses by **GID**, and a device exposes several — pass the index
whose address matches the IP you connect over. List them:

```bash
ibv_devinfo -v -d rxe0 | grep -iE 'GID|RoCE'   # if libibverbs-utils present
# no ibv_devinfo? read sysfs directly:
cat /sys/class/infiniband/rxe0/ports/1/gids/*
```

For an `rxe`-over-`lo` test reaching `127.0.0.1`, use the **IPv4-mapped**
entry (`::ffff:7f00:0001`), which is typically **index 1**; index 0 is the
link-local `fe80::` GID and fails with `Network is unreachable`. (Verified
on a Soft-RoCE loopback.) Pass the same index on **both** sides — a wrong
one causes the §6 symptoms.

## 4. Build

```bash
cc -O2 -o rdma-hello rdma-hello.c -libverbs
```

## 5. Run

**Single box (rxe over `lo`), two terminals:**

```bash
# terminal 1   (replace <gididx> with the RoCEv2 index from step 3)
./rdma-hello server 18515 <gididx>
# terminal 2
./rdma-hello client 127.0.0.1 18515 <gididx>
```

**Two hosts** (server = 192.168.1.10, both with rxe over their NIC):

```bash
# on the server
./rdma-hello server 18515 <gid_index>
# on the client
./rdma-hello client 192.168.1.10 18515 <gid_index>
```

Expected output (each side):

```
using RDMA device rxe0, gid_index 1
waiting for peer on TCP :18515 ...      # server only
local  qpn=17 psn=10330473
remote qpn=18 psn=4711234
received: "hello from client (pid 12345)"
```

## 6. Troubleshooting

- **"no RDMA devices"** — the `rxe` link isn't up: re-run §2, check
  `rdma link` shows `state ACTIVE`.
- **`RNR retry exceeded`, or `timed out waiting for completion`** — almost
  always a wrong `gid_index` (RoCEv1 vs RoCEv2, or wrong subnet). Re-check
  §3 and pass the matching index on **both** sides.
- **`bad server IP` / connect timeout** — the TCP rendezvous (port 18515)
  is blocked or the IP is wrong; open the port / use the rxe-bound IP.
- **`modify -> RTR` fails with `Network is unreachable`** — the chosen GID
  can't reach the peer IP (e.g. a link-local `fe80::` GID for a `127.0.0.1`
  target); pick the GID matching your target IP (§3). `GID index out of
  range` instead means the index is too high — lower it.

## 7. What this is NOT

Teaching code: two-sided SEND/RECV, one message each way, single
connection, terse error handling, and a not-endian-safe struct exchange
(fine for same-arch peers). The post's headline feature — **one-sided**
`RDMA WRITE`/`READ` into a peer's registered memory — is the natural next
step: on the side being written *into*, register its buffer with
`IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE` (REMOTE_WRITE requires
LOCAL_WRITE) and send that buffer's `{addr, rkey}` to the writer; the
writer then posts an `IBV_WR_RDMA_WRITE` work request with
`wr.rdma.remote_addr` / `wr.rdma.rkey` set to those values.
