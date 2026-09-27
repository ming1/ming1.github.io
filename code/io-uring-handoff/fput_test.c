// SPDX-License-Identifier: GPL-2.0
/*
 * fput_test <dir>: does the file of an io_uring CLOSE get released before
 * io_uring_enter() returns, when a later SQE of the same call blocks?
 *
 * One io_uring_enter() submits CLOSE(fd holding flock) then FSYNC(big dirty
 * file). A child tries flock(LOCK_EX|LOCK_NB) on the same file in a loop.
 * The lock is dropped when the closed file is released (__fput()). The
 * last fput of an inline CLOSE is task_work (TWA_RESUME) on the submitter,
 * so without a handoff it runs before io_uring_enter() returns.
 *
 * Prints, in ms from the submit: when io_uring_enter() returned, when the
 * CLOSE and FSYNC CQEs arrived, and when the child got the lock.
 */
#include <fcntl.h>
#include <liburing.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv)
{
	char lockpath[512], bigpath[512];
	struct io_uring ring;
	struct io_uring_sqe *sqe;
	struct io_uring_cqe *cqe;
	double *shm, t0, t_ret, t_close = -1, t_fsync = -1;
	int pfd[2], fda, fdb, i, ret;
	static char buf[1 << 20];
	pid_t pid;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <dir>\n", argv[0]);
		return 2;
	}
	snprintf(lockpath, sizeof(lockpath), "%s/fput.lock", argv[1]);
	snprintf(bigpath, sizeof(bigpath), "%s/fput.big", argv[1]);
	close(open(lockpath, O_CREAT | O_RDWR, 0644));

	/* shm[0] = submit time t0, shm[1] = time the child got the lock */
	shm = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
		   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (shm == MAP_FAILED || pipe(pfd))
		return 1;

	/* fork before opening the file: the child must not share its ref */
	pid = fork();
	if (!pid) {
		char c;
		int fd;

		close(pfd[1]);
		if (read(pfd[0], &c, 1) != 1)
			_exit(1);
		fd = open(lockpath, O_RDWR);
		for (i = 0; i < 100000; i++) {
			if (!flock(fd, LOCK_EX | LOCK_NB)) {
				shm[1] = now_ms();
				_exit(0);
			}
			usleep(200);
		}
		_exit(1);
	}
	close(pfd[0]);

	if (io_uring_queue_init(8, &ring, 0))
		return 1;
	/* create the io_uring task context; it forks a spare io-wq worker */
	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_nop(sqe);
	io_uring_submit_and_wait(&ring, 1);
	io_uring_wait_cqe(&ring, &cqe);
	io_uring_cqe_seen(&ring, cqe);
	usleep(300000);

	/* a big dirty file, so its FSYNC blocks for a while */
	fdb = open(bigpath, O_CREAT | O_TRUNC | O_RDWR, 0644);
	memset(buf, 0xa5, sizeof(buf));
	for (i = 0; i < 64; i++)
		if (write(fdb, buf, sizeof(buf)) != sizeof(buf))
			return 1;

	fda = open(lockpath, O_RDWR);
	if (flock(fda, LOCK_EX))
		return 1;
	/* the child starts polling: it must fail until our file is released */
	if (write(pfd[1], "g", 1) != 1)
		return 1;
	usleep(20000);

	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_close(sqe, fda);
	sqe->user_data = 1;
	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_fsync(sqe, fdb, 0);
	sqe->user_data = 2;

	t0 = now_ms();
	shm[0] = t0;
	ret = io_uring_submit(&ring);		/* one io_uring_enter() */
	t_ret = now_ms();
	if (ret != 2) {
		fprintf(stderr, "submit %d\n", ret);
		return 1;
	}
	for (i = 0; i < 2; i++) {
		if (io_uring_wait_cqe(&ring, &cqe))
			return 1;
		if (cqe->user_data == 1)
			t_close = now_ms();
		else
			t_fsync = now_ms();
		if (cqe->res < 0)
			fprintf(stderr, "op %llu: %s\n", cqe->user_data,
				strerror(-cqe->res));
		io_uring_cqe_seen(&ring, cqe);
	}
	waitpid(pid, &ret, 0);

	printf("enter_ret %.1f close_cqe %.1f fsync_cqe %.1f lock_free %.1f\n",
	       t_ret - t0, t_close - t0, t_fsync - t0,
	       shm[1] ? shm[1] - t0 : -1.0);
	/* released late: after the syscall returned, near the FSYNC's end */
	printf("RESULT %s\n", shm[1] - t0 > t_ret - t0 + 5 ?
	       "LATE_RELEASE" : "RELEASED_BEFORE_RETURN");
	unlink(bigpath);
	return 0;
}
