// SPDX-License-Identifier: MIT
/*
 * rdma-hello.c - a minimal RDMA SEND/RECV "hello", using *libibverbs*
 * only (plus a throwaway TCP socket for the rendezvous; no librdmacm).
 *
 * Two peers build a Reliable Connected (RC) queue pair, swap the raw
 * connection parameters (QPN, PSN, LID, GID) over TCP, drive the QP
 * through the RESET -> INIT -> RTR -> RTS state machine by hand, then
 * each SENDs a greeting and RECVs the other's. This is exactly the "raw
 * QP bring-up" that librdmacm/rdma_cm hides -- see the blog post
 * "RDMA from Top to Bottom", section 3 (programming model) and 4 (kernel
 * + RDMA CM). The steps below are tagged [1]..[12].
 *
 * No special hardware required: run it over Soft-RoCE (the rdma_rxe
 * kernel module) on an ordinary NIC or even loopback. See
 * rdma-hello.README.md for environment setup and how to run it.
 *
 * Build:  cc -O2 -o rdma-hello rdma-hello.c -libverbs
 * Run:    ./rdma-hello server [port] [gid_index]
 *         ./rdma-hello client <server-ip> [port] [gid_index]
 *   Pass the RoCEv2 gid_index if the default (0) is not RoCEv2; the
 *   README shows how to find it.
 *
 * Error handling is terse to keep the verbs flow readable. The conn-info
 * exchange is not endian-safe (fine for same-arch peers, which is the
 * common case for a demo).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <infiniband/verbs.h>

#define IB_PORT  1          /* HCA physical port, usually 1 */
#define MSG_SIZE 256
#define PORT_DEFAULT 18515

#define die(m)     do { perror(m); exit(1); } while (0)
#define diex(...)  do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)

/* What each side must learn about the other to wire up the QP. */
struct conn_info {
	uint32_t qpn;       /* remote QP number              */
	uint32_t psn;       /* remote starting packet seq no */
	uint16_t lid;       /* local id (0 on RoCE/Ethernet) */
	uint8_t  gid[16];   /* RoCE address                  */
} __attribute__((packed));

/* ---- tiny TCP rendezvous (out-of-band, not part of RDMA) ---- */

static ssize_t readn(int fd, void *buf, size_t n)
{
	size_t off = 0;
	while (off < n) {
		ssize_t r = read(fd, (char *)buf + off, n - off);
		if (r <= 0)
			return r;
		off += r;
	}
	return off;
}

static int tcp_setup(int is_server, const char *host, int port)
{
	struct sockaddr_in sa = { .sin_family = AF_INET,
				  .sin_port = htons(port) };
	int fd;

	if (is_server) {
		int lfd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
		if (lfd < 0)
			die("socket");
		setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
		sa.sin_addr.s_addr = htonl(INADDR_ANY);
		if (bind(lfd, (struct sockaddr *)&sa, sizeof sa))
			die("bind");
		if (listen(lfd, 1))
			die("listen");
		printf("waiting for peer on TCP :%d ...\n", port);
		fd = accept(lfd, NULL, NULL);
		if (fd < 0)
			die("accept");
		close(lfd);
	} else {
		fd = socket(AF_INET, SOCK_STREAM, 0);
		if (fd < 0)
			die("socket");
		if (inet_pton(AF_INET, host, &sa.sin_addr) != 1)
			diex("bad server IP: %s\n", host);
		if (connect(fd, (struct sockaddr *)&sa, sizeof sa))
			die("connect");
	}
	return fd;
}

/* exchange a fixed-size blob: write ours, read theirs */
static void tcp_swap(int fd, const void *out, void *in, size_t n)
{
	if (write(fd, out, n) != (ssize_t)n)
		die("tcp write");
	if (readn(fd, in, n) != (ssize_t)n)
		diex("tcp short read\n");
}

/* 1-byte barrier so both sides reach the same point */
static void tcp_barrier(int fd)
{
	char b = 'x';
	tcp_swap(fd, &b, &b, 1);
}

int main(int argc, char **argv)
{
	const char *peer = NULL;
	int is_server, port = PORT_DEFAULT, gididx = 0;

	if (argc >= 2 && !strcmp(argv[1], "server")) {
		is_server = 1;
		if (argc >= 3) port = atoi(argv[2]);
		if (argc >= 4) gididx = atoi(argv[3]);
	} else if (argc >= 3 && !strcmp(argv[1], "client")) {
		is_server = 0;
		peer = argv[2];
		if (argc >= 4) port = atoi(argv[3]);
		if (argc >= 5) gididx = atoi(argv[4]);
	} else {
		diex("usage:\n"
		     "  %s server [port] [gid_index]\n"
		     "  %s client <server-ip> [port] [gid_index]\n",
		     argv[0], argv[0]);
	}

	/* [1] open the first RDMA device */
	int ndev;
	struct ibv_device **devs = ibv_get_device_list(&ndev);
	if (!devs || !ndev)
		diex("no RDMA devices -- is rdma_rxe loaded? (see README)\n");
	struct ibv_context *ctx = ibv_open_device(devs[0]);
	if (!ctx)
		die("ibv_open_device");
	printf("using RDMA device %s, gid_index %d\n",
	       ibv_get_device_name(devs[0]), gididx);

	/* [2] protection domain, [3] completion queue */
	struct ibv_pd *pd = ibv_alloc_pd(ctx);
	if (!pd)
		die("ibv_alloc_pd");
	struct ibv_cq *cq = ibv_create_cq(ctx, 16, NULL, NULL, 0);
	if (!cq)
		die("ibv_create_cq");

	/* [4] register send/recv buffers as memory regions */
	char *send_buf = calloc(1, MSG_SIZE), *recv_buf = calloc(1, MSG_SIZE);
	if (!send_buf || !recv_buf)
		die("calloc");
	struct ibv_mr *send_mr = ibv_reg_mr(pd, send_buf, MSG_SIZE,
					    IBV_ACCESS_LOCAL_WRITE);
	struct ibv_mr *recv_mr = ibv_reg_mr(pd, recv_buf, MSG_SIZE,
					    IBV_ACCESS_LOCAL_WRITE);
	if (!send_mr || !recv_mr)
		die("ibv_reg_mr");

	/* [5] create the RC queue pair, both work queues feeding one CQ */
	struct ibv_qp_init_attr qia = {
		.send_cq = cq, .recv_cq = cq, .qp_type = IBV_QPT_RC,
		.cap = { .max_send_wr = 1, .max_recv_wr = 1,
			 .max_send_sge = 1, .max_recv_sge = 1 },
	};
	struct ibv_qp *qp = ibv_create_qp(pd, &qia);
	if (!qp)
		die("ibv_create_qp");

	/* [6] RESET -> INIT */
	struct ibv_qp_attr ini = {
		.qp_state = IBV_QPS_INIT, .pkey_index = 0,
		.port_num = IB_PORT, .qp_access_flags = 0,
	};
	if (ibv_modify_qp(qp, &ini, IBV_QP_STATE | IBV_QP_PKEY_INDEX |
				    IBV_QP_PORT | IBV_QP_ACCESS_FLAGS))
		die("modify -> INIT");

	/* gather our connection parameters */
	struct ibv_port_attr pa;
	if (ibv_query_port(ctx, IB_PORT, &pa))
		die("ibv_query_port");
	union ibv_gid mygid;
	if (ibv_query_gid(ctx, IB_PORT, gididx, &mygid))
		die("ibv_query_gid");
	srand48(getpid());
	struct conn_info local = { .qpn = qp->qp_num,
				   .psn = lrand48() & 0xffffff,
				   .lid = pa.lid };
	memcpy(local.gid, &mygid, 16);

	/* [7] swap connection parameters with the peer over TCP */
	int fd = tcp_setup(is_server, peer, port);
	struct conn_info remote;
	tcp_swap(fd, &local, &remote, sizeof local);
	printf("local  qpn=%u psn=%u\nremote qpn=%u psn=%u\n",
	       local.qpn, local.psn, remote.qpn, remote.psn);

	/* [8] INIT -> RTR: point the QP at the remote (RoCE uses the GID) */
	union ibv_gid rgid;
	memcpy(&rgid, remote.gid, 16);
	struct ibv_qp_attr rtr = {
		.qp_state = IBV_QPS_RTR,
		.path_mtu = IBV_MTU_1024,
		.dest_qp_num = remote.qpn,
		.rq_psn = remote.psn,
		.max_dest_rd_atomic = 1,
		.min_rnr_timer = 12,
		.ah_attr = {
			.is_global = 1,           /* RoCE: address by GID */
			.dlid = remote.lid,
			.sl = 0, .src_path_bits = 0, .port_num = IB_PORT,
			.grh = { .dgid = rgid, .sgid_index = gididx,
				 .hop_limit = 1 },
		},
	};
	if (ibv_modify_qp(qp, &rtr, IBV_QP_STATE | IBV_QP_AV |
				    IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
				    IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC |
				    IBV_QP_MIN_RNR_TIMER))
		die("modify -> RTR");

	/* [9] RTR -> RTS */
	struct ibv_qp_attr rts = {
		.qp_state = IBV_QPS_RTS, .timeout = 14, .retry_cnt = 7,
		.rnr_retry = 7, .sq_psn = local.psn, .max_rd_atomic = 1,
	};
	if (ibv_modify_qp(qp, &rts, IBV_QP_STATE | IBV_QP_TIMEOUT |
				    IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
				    IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC))
		die("modify -> RTS");

	/* [10] post a RECV before anyone SENDs */
	struct ibv_sge rsge = { (uintptr_t)recv_buf, MSG_SIZE, recv_mr->lkey };
	struct ibv_recv_wr rwr = { .wr_id = 1, .sg_list = &rsge,
				   .num_sge = 1 }, *rbad;
	if (ibv_post_recv(qp, &rwr, &rbad))
		die("ibv_post_recv");

	tcp_barrier(fd);   /* both RECVs are posted before any SEND */

	/* [11] post a SEND carrying our greeting */
	snprintf(send_buf, MSG_SIZE, "hello from %s (pid %d)",
		 is_server ? "server" : "client", getpid());
	struct ibv_sge ssge = { (uintptr_t)send_buf,
				(uint32_t)strlen(send_buf) + 1, send_mr->lkey };
	struct ibv_send_wr swr = { .wr_id = 2, .opcode = IBV_WR_SEND,
				   .sg_list = &ssge, .num_sge = 1,
				   .send_flags = IBV_SEND_SIGNALED }, *sbad;
	if (ibv_post_send(qp, &swr, &sbad))
		die("ibv_post_send");

	/* [12] reap both completions (our SEND + the inbound RECV).
	 * Bounded so a misconfigured gid_index fails loudly, not silently. */
	time_t deadline = time(NULL) + 10;
	for (int got = 0; got < 2; ) {
		struct ibv_wc wc;
		int c = ibv_poll_cq(cq, 1, &wc);
		if (c < 0)
			diex("ibv_poll_cq failed\n");
		if (c == 0) {
			if (time(NULL) > deadline)
				diex("timed out waiting for completion -- check "
				     "gid_index (RoCEv2?) and peer reachability\n");
			continue;
		}
		if (wc.status != IBV_WC_SUCCESS)
			diex("completion error: %s (wr_id=%llu)\n",
			     ibv_wc_status_str(wc.status),
			     (unsigned long long)wc.wr_id);
		got++;
	}
	printf("received: \"%s\"\n", recv_buf);

	tcp_barrier(fd);   /* don't tear down before the peer is done */

	ibv_destroy_qp(qp);
	ibv_destroy_cq(cq);
	ibv_dereg_mr(send_mr);
	ibv_dereg_mr(recv_mr);
	ibv_dealloc_pd(pd);
	ibv_close_device(ctx);
	ibv_free_device_list(devs);
	close(fd);
	return 0;
}
