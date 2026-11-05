// SPDX-License-Identifier: GPL-2.0
/*
 * ublk-del-dev: issue one raw UBLK_U_CMD_DEL_DEV (or DEL_DEV_ASYNC) on
 * /dev/ublk-control, without STOP_DEV first, the way libublk does.
 *
 * kublk's "del" and ublksrv's "ublk del" both run STOP_DEV before DEL_DEV,
 * which hides the global ublk_ctl_mutex hang this tool reproduces.
 *
 * build: cc -O2 -o ublk-del-dev ublk-del-dev.c -luring
 * usage: ublk-del-dev <dev_id> [async]
 */
#include <fcntl.h>
#include <liburing.h>
#include <linux/ublk_cmd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct io_uring_sqe *sqe;
	struct io_uring_cqe *cqe;
	struct ublksrv_ctrl_cmd *cmd;
	struct io_uring ring;
	int fd, ret;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <dev_id> [async]\n", argv[0]);
		return 2;
	}

	fd = open("/dev/ublk-control", O_RDWR);
	if (fd < 0) {
		perror("/dev/ublk-control");
		return 1;
	}
	ret = io_uring_queue_init(4, &ring, IORING_SETUP_SQE128);
	if (ret < 0) {
		fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-ret));
		return 1;
	}

	sqe = io_uring_get_sqe(&ring);
	sqe->fd = fd;
	sqe->opcode = IORING_OP_URING_CMD;
	sqe->cmd_op = argc > 2 ? UBLK_U_CMD_DEL_DEV_ASYNC : UBLK_U_CMD_DEL_DEV;
	cmd = (struct ublksrv_ctrl_cmd *)sqe->cmd;
	memset(cmd, 0, sizeof(*cmd));
	cmd->dev_id = atoi(argv[1]);
	cmd->queue_id = -1;

	ret = io_uring_submit(&ring);
	if (ret < 0) {
		fprintf(stderr, "submit: %s\n", strerror(-ret));
		return 1;
	}
	ret = io_uring_wait_cqe(&ring, &cqe);
	if (ret < 0) {
		fprintf(stderr, "wait_cqe: %s\n", strerror(-ret));
		return 1;
	}
	ret = cqe->res;
	io_uring_cqe_seen(&ring, cqe);
	printf("DEL_DEV %s: %d (%s)\n", argv[1], ret,
	       ret < 0 ? strerror(-ret) : "ok");
	return ret < 0 ? 1 : 0;
}
