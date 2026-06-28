// SPDX-License-Identifier: MIT
/*
 * iou-recvzc-min.c - the smallest io_uring zero-copy receive (RECV_ZC)
 * example, written to *understand the API*, not for production use.
 *
 * RECV_ZC lands TCP payload directly into a pre-registered memory "area"
 * via the NIC's page-pool memory provider (zcrx). The application reads
 * the bytes in place and returns each consumed buffer to the kernel
 * through a dedicated "refill ring". Companion blog post:
 *   "Linux io_uring net send/recv explained" -> the
 *   "Zero-copy receive (RECV_ZC), top to bottom" section.
 *
 * This WILL NOT run on an arbitrary machine. RECV_ZC is hardware-gated:
 *   - Linux kernel >= 6.15 with CONFIG_IO_URING_ZCRX=y, and kernel uapi
 *     headers recent enough to define the zcrx structs (a recent
 *     linux-libc-dev / kernel-headers). Any liburing with the base
 *     io_uring_register() works -- this file uses the raw
 *     IORING_REGISTER_ZCRX_IFQ, not the newer io_uring_register_ifq().
 *   - A NIC/driver with TCP header-data split + unreadable netmem:
 *     mlx5e, bnxt_en (queue API), gve (DQO), or fbnic.
 *   - The RX queue prepared and a flow steered onto it, e.g.:
 *       ethtool -G <if> tcp-data-split on
 *       ethtool -G <if> hds-thresh 0          # all payload to the area
 *       ethtool -X <if> equal 1               # (example) single queue
 *       ethtool -N <if> flow-type tcp6 dst-port <port> action <rxq>
 *     with no XDP / AF_XDP bound to that queue.
 *   - CAP_NET_ADMIN (run as root).
 *
 * Build:  cc -O2 -o iou-recvzc-min iou-recvzc-min.c -luring
 * Run:    ./iou-recvzc-min <ifname> <rx-queue-id> <tcp-port>
 *         then, from a peer, connect to this host:<port> and send data.
 *
 * Error handling is deliberately terse so the zcrx control flow stays
 * visible. The five steps that matter are tagged [1]..[5] below.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <net/if.h>
/*
 * Include the kernel uapi header BEFORE <liburing.h>. Both share the
 * LINUX_IO_URING_H include guard, so the first one wins; pulling the
 * system header first gives the complete zcrx struct definitions even
 * when an older liburing bundles an incomplete copy. Needs recent kernel
 * uapi headers (linux-libc-dev / kernel-headers). If your liburing is new
 * enough to define zcrx itself, this include is harmless.
 */
#include <linux/io_uring.h>
#include <liburing.h>

#define AREA_SIZE   (16u << 20)   /* 16 MiB registered receive area */
#define RQ_ENTRIES  4096          /* refill ring slots (power of two) */
#define UD_RECVZC   1             /* SQE user_data tag for our recv   */

#define die(msg) do { perror(msg); exit(1); } while (0)

/* Userspace view of the refill ring (app is the producer here). */
struct refill_ring {
	uint32_t			*ktail;	/* app advances this */
	struct io_uring_zcrx_rqe	*rqes;
	uint32_t			 mask;
	uint32_t			 tail;	/* cached producer index */
};

static void		*area;		/* the registered RX memory  */
static struct refill_ring rq;
static uint64_t		 area_token;	/* opaque area id for refills */

/* [1] Register a zcrx "interface queue": bind an mmap'd memory area and a
 *     refill ring to one NIC RX queue. After this, the driver allocates
 *     RX buffers from `area`, so received payload lands there directly. */
static void setup_zcrx(struct io_uring *ring, unsigned ifindex, unsigned rxq)
{
	size_t rsize;
	void *region;

	/* The area: where the NIC DMAs payload. Userspace mmaps it and
	 * reads packets in place; the CQE reports an offset into it. */
	area = mmap(NULL, AREA_SIZE, PROT_READ | PROT_WRITE,
		    MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	if (area == MAP_FAILED)
		die("mmap area");

	/* The refill ring lives in a user-allocated region: rqe array plus
	 * one page for the head/tail header. */
	rsize = RQ_ENTRIES * sizeof(struct io_uring_zcrx_rqe);
	rsize += sysconf(_SC_PAGESIZE);
	region = mmap(NULL, rsize, PROT_READ | PROT_WRITE,
		      MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	if (region == MAP_FAILED)
		die("mmap refill region");

	struct io_uring_region_desc region_desc = {
		.size      = rsize,
		.user_addr = (uint64_t)(uintptr_t)region,
		.flags     = IORING_MEM_REGION_TYPE_USER,
	};
	struct io_uring_zcrx_area_reg area_reg = {
		.addr = (uint64_t)(uintptr_t)area,
		.len  = AREA_SIZE,
	};
	struct io_uring_zcrx_ifq_reg reg = {
		.if_idx      = ifindex,
		.if_rxq      = rxq,
		.rq_entries  = RQ_ENTRIES,
		.area_ptr    = (uint64_t)(uintptr_t)&area_reg,
		.region_ptr  = (uint64_t)(uintptr_t)&region_desc,
	};

	/* Raw register avoids needing liburing's newer io_uring_register_ifq()
	 * helper; the kernel requires nr_args == 1 for ZCRX_IFQ. */
	if (io_uring_register(ring->ring_fd, IORING_REGISTER_ZCRX_IFQ, &reg, 1))
		die("IORING_REGISTER_ZCRX_IFQ");

	/* The kernel filled in reg.offsets and area_reg.rq_area_token. Wire
	 * up our refill-ring pointers into the mmap'd region. */
	rq.ktail = (uint32_t *)((char *)region + reg.offsets.tail);
	rq.rqes  = (struct io_uring_zcrx_rqe *)
		   ((char *)region + reg.offsets.rqes);
	rq.mask  = reg.rq_entries - 1;
	rq.tail  = 0;
	area_token = area_reg.rq_area_token;
}

/* [2] Arm a multishot RECV_ZC: one long-lived request that posts an aux
 *     CQE per arrival. There is no buffer pointer - the data goes to the
 *     registered area, not a userspace buffer. */
static void arm_recvzc(struct io_uring *ring, int fd)
{
	struct io_uring_sqe *sqe = io_uring_get_sqe(ring);

	io_uring_prep_rw(IORING_OP_RECV_ZC, sqe, fd, NULL, 0, 0);
	sqe->ioprio |= IORING_RECV_MULTISHOT;
	sqe->user_data = UD_RECVZC;
}

/* [3..5] Handle one RECV_ZC completion. Returns 0 to keep going, 1 on
 *        peer close. */
static int handle_recvzc(struct io_uring *ring, int fd,
			 struct io_uring_cqe *cqe)
{
	/* peer closed: res == 0 with no IORING_CQE_F_MORE */
	if (cqe->res == 0 && !(cqe->flags & IORING_CQE_F_MORE))
		return 1;
	if (cqe->res < 0) {
		fprintf(stderr, "recvzc: %s\n", strerror(-cqe->res));
		return 1;
	}

	/* [3] The zcrx payload descriptor rides in the second half of the
	 *     32-byte CQE (that is why the ring needs IORING_SETUP_CQE32). */
	struct io_uring_zcrx_cqe *rcqe = (struct io_uring_zcrx_cqe *)(cqe + 1);

	/* [4] Read the bytes in place. The low IORING_ZCRX_AREA_SHIFT bits of
	 *     rcqe->off are the byte offset into our area; the high bits are
	 *     the area id. No copy happened on the way here. */
	uint64_t mask = (1ULL << IORING_ZCRX_AREA_SHIFT) - 1;
	char *data = (char *)area + (rcqe->off & mask);
	unsigned len = cqe->res;

	printf("recv %u bytes at area+%llu (first byte 0x%02x)\n",
	       len, (unsigned long long)(rcqe->off & mask),
	       len ? (unsigned char)data[0] : 0);

	/* [5] Return the consumed buffer to the kernel via the refill ring:
	 *     write {offset|area_token, len} into the next rqe and publish
	 *     the new tail with a store-release. Now the niov can cycle back
	 *     to the NIC. */
	struct io_uring_zcrx_rqe *rqe = &rq.rqes[rq.tail & rq.mask];
	rqe->off = (rcqe->off & ~(uint64_t)IORING_ZCRX_AREA_MASK) | area_token;
	rqe->len = len;
	io_uring_smp_store_release(rq.ktail, ++rq.tail);

	/* Re-arm if the multishot request terminated (e.g. ran out of CQEs). */
	if (!(cqe->flags & IORING_CQE_F_MORE))
		arm_recvzc(ring, fd);

	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: %s <ifname> <rx-queue-id> <port>\n",
			argv[0]);
		return 2;
	}
	unsigned ifindex = if_nametoindex(argv[1]);
	if (!ifindex)
		die("if_nametoindex");
	unsigned rxq = strtoul(argv[2], NULL, 0);
	unsigned port = strtoul(argv[3], NULL, 0);

	/* Plain blocking TCP listener (kept out of io_uring for brevity). */
	int lfd = socket(AF_INET6, SOCK_STREAM, 0);
	if (lfd < 0)
		die("socket");
	int one = 1;
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in6 sa = {
		.sin6_family = AF_INET6,
		.sin6_addr   = in6addr_any,
		.sin6_port   = htons(port),
	};
	if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)))
		die("bind");
	if (listen(lfd, 1))
		die("listen");

	/* zcrx wants single-issuer + deferred task-run, and CQE32 so the
	 * io_uring_zcrx_cqe fits after each CQE. */
	struct io_uring ring;
	unsigned flags = IORING_SETUP_CQE32 | IORING_SETUP_SINGLE_ISSUER |
			 IORING_SETUP_DEFER_TASKRUN;
	if (io_uring_queue_init(512, &ring, flags))
		die("io_uring_queue_init");

	setup_zcrx(&ring, ifindex, rxq);

	printf("listening on [::]:%u, zcrx on %s rxq %u\n",
	       port, argv[1], rxq);
	int cfd = accept(lfd, NULL, NULL);
	if (cfd < 0)
		die("accept");

	arm_recvzc(&ring, cfd);

	for (;;) {
		struct io_uring_cqe *cqe;
		unsigned head, count = 0;
		int done = 0;

		if (io_uring_submit_and_wait(&ring, 1) < 0)
			die("submit_and_wait");

		io_uring_for_each_cqe(&ring, head, cqe) {
			count++;
			if (cqe->user_data == UD_RECVZC)
				done |= handle_recvzc(&ring, cfd, cqe);
		}
		io_uring_cq_advance(&ring, count);
		if (done)
			break;
	}

	printf("peer closed, received done\n");
	io_uring_queue_exit(&ring);
	close(cfd);
	close(lfd);
	return 0;
}
