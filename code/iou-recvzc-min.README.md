# iou-recvzc-min — testing the io_uring RECV_ZC example

`iou-recvzc-min.c` is a smallest-possible io_uring **zero-copy receive**
(RECV_ZC / zcrx) server, written to *understand the API*. See the
companion blog post, "Linux io_uring net send/recv explained" → the
"Zero-copy receive (RECV_ZC), top to bottom" section.

RECV_ZC is **hardware-gated**: it only does true zero-copy on a NIC/driver
that can split TCP **headers** (to ordinary kernel memory) from
**payload** (DMA'd into a pre-registered area via a page-pool memory
provider). You cannot run it on an arbitrary box.

## 0. Capable hardware (pick one)

- **NVIDIA/Mellanox ConnectX-5/6/7** — `mlx5e`
- **Broadcom NetXtreme** with the queue API — `bnxt_en`
- **Google Cloud** instances with gVNIC in **DQO** mode — `gve`
  (easiest "rent it for an hour" option)
- **Meta fbnic** — `fbnic`

## 1. Software

- Kernel **≥ 6.15** with `CONFIG_IO_URING_ZCRX=y`:
  ```
  grep IO_URING_ZCRX /boot/config-$(uname -r)
  ```
- **liburing ≥ 2.9 / git master** — must provide `io_uring_register_ifq()`.
  Distro liburing is usually too old; build from source and link against
  it. (The example fails to build *only* because of an old liburing.)

## 2. Validate the environment first (recommended)

Before trusting this minimal example, run the kernel's own zcrx selftest —
it is the ground truth and prints clear skip reasons if the driver/NIC
isn't ready:

```
tools/testing/selftests/drivers/net/hw/iou-zcrx.py     # driver-side check
# (or build & run iou-zcrx.c directly as a server/client pair)
```

If the selftest passes on your `<iface>` / `<rxq>`, this example will too.

## 3. Configure the NIC

Driver-specific; these are the common knobs. `ethtool -g $IF` shows
whether `tcp-data-split` / `hds-thresh` are supported — if they're absent,
that driver build cannot do true zero-copy.

```bash
IF=eth1            # the zcrx-capable interface
RXQ=1              # an RX queue you will steer the test flow onto
PORT=9999

sudo ethtool -G $IF tcp-data-split on    # split headers vs payload
sudo ethtool -G $IF hds-thresh 0         # all payload into the area
sudo ethtool -K $IF ntuple on
# steer the test connection onto $RXQ so payload lands in the zcrx area:
sudo ethtool -N $IF flow-type tcp4 dst-port $PORT action $RXQ
# make sure no XDP / AF_XDP is bound to $IF / $RXQ
```

## 4. Build and run the server

```bash
cc -O2 -o iou-recvzc-min iou-recvzc-min.c -luring   # the new liburing
sudo ./iou-recvzc-min $IF $RXQ $PORT
```

It prints `recv N bytes at area+OFF …` per arrival — payload it read
**in place** from the registered area, with no copy.

## 5. Drive traffic from a peer

From another host that routes to `$IF`'s address:

```bash
dd if=/dev/zero bs=1M count=512 | nc <server-ip-on-IF> 9999
```

## 6. Confirm it was actually zero-copy

zcrx silently **copies** fragments that did not land in the registered
area (headers, or a misconfigured queue). To prove real ZC:

- Watch the driver's HDS / per-queue counters during the run:
  ```bash
  watch -n1 'ethtool -S '$IF' | grep -iE "hds|rx_'$RXQ'"'
  ```
  payload bytes should track the queue you steered to, with the
  copy-fallback path quiet.
- Or trace the kernel fallback directly:
  ```bash
  sudo bpftrace -e 'kprobe:io_zcrx_copy_frag { @copies = count(); }'
  ```
  `@copies` near 0 under load → true zero-copy; climbing → header-data
  split or flow steering is not taking effect.

## Cheapest end-to-end recipe

Two GCP VMs with gVNIC (DQO), a recent kernel + liburing: run the kernel
selftest to confirm the environment, then point this example at the
gVNIC RX queue. Avoids needing physical ConnectX hardware.

## What this example is NOT

Read-don't-run teaching code, single connection, terse error handling. A
real application must additionally: bound the refill ring against the
kernel head index (`reg.offsets.head`), null-check `io_uring_get_sqe()`,
handle `res < 0` requeue/cancel cases, and manage multiple connections.
