// SPDX-License-Identifier: GPL-2.0
/*
 * Helper H for a UBLK_F_BATCH_IO device: take a reference on the server's
 * /dev/ublkcN with pidfd_getfd() and issue a batch uring_cmd through it.
 * Prints the CQE result: what ublk thinks of a command from a non-owner.
 *   usage: steal_cmd <server pid> <server's ublkc fd>
 */
#define _GNU_SOURCE
#include <liburing.h>
#include <linux/ublk_cmd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct io_uring ring;
	struct io_uring_sqe *sqe;
	struct io_uring_cqe *cqe;
	struct ublk_batch_io *uc;
	int pidfd, fd, ret;

	pidfd = syscall(SYS_pidfd_open, atoi(argv[1]), 0);
	fd = syscall(SYS_pidfd_getfd, pidfd, atoi(argv[2]), 0);
	if (fd < 0) {
		perror("pidfd_getfd");
		return 1;
	}
	ret = io_uring_queue_init(4, &ring, IORING_SETUP_SQE128);
	if (ret < 0)
		return 1;
	sqe = io_uring_get_sqe(&ring);
	memset(sqe, 0, 128);
	sqe->opcode = IORING_OP_URING_CMD;
	sqe->fd = fd;
	sqe->cmd_op = UBLK_U_IO_COMMIT_IO_CMDS;
	uc = (struct ublk_batch_io *)sqe->cmd;
	uc->q_id = 0;
	uc->nr_elem = 1;
	uc->elem_bytes = sizeof(struct ublk_elem_header);
	io_uring_submit(&ring);
	ret = io_uring_wait_cqe(&ring, &cqe);
	if (ret < 0)
		return 1;
	printf("HELPER %d: COMMIT_IO_CMDS via stolen ublkc fd -> res %d (%s)\n",
	       getpid(), cqe->res, cqe->res < 0 ? strerror(-cqe->res) : "accepted");
	return 0;
}
