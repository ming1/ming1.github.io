// SPDX-License-Identifier: GPL-2.0
/*
 * fput_test <dir>: after the CQE of an io_uring CLOSE, is the file really
 * closed, when a later SQE of the same io_uring_enter() blocks?
 *
 * The file holds a flock, and the flock goes away only when the file is
 * released (__fput()). One io_uring_enter() submits CLOSE(that fd) and
 * FSYNC(big dirty file). When each CQE arrives, we check from userspace:
 *  - flock(LOCK_EX | LOCK_NB) on a new fd: EWOULDBLOCK while the closed
 *    file is still open;
 *  - /proc/locks: the flock entry of the file's inode.
 *
 * Expected: without a handoff, the file is released before io_uring_enter()
 * returns. With a handoff, the last fput runs on the old submitter after
 * the FSYNC completes, so the CLOSE CQE is seen while the file is open.
 */
#include <fcntl.h>
#include <liburing.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char lockpath[512];

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* returns 1 if the closed file still holds its flock */
static int observe(const char *when, double t)
{
	char line[256], key[32];
	struct stat st;
	FILE *fp;
	int fd, held;

	fd = open(lockpath, O_RDWR);
	held = flock(fd, LOCK_EX | LOCK_NB) != 0;
	close(fd);
	printf("%-16s %6.1f ms: flock(new fd) %s\n", when, t,
	       held ? "EWOULDBLOCK, the file is still open" :
		      "ok, the file is released");

	stat(lockpath, &st);
	snprintf(key, sizeof(key), ":%lu ", (unsigned long)st.st_ino);
	fp = fopen("/proc/locks", "r");
	while (fp && fgets(line, sizeof(line), fp))
		if (strstr(line, key))
			printf("%-16s /proc/locks: %s", "", line);
	if (fp)
		fclose(fp);
	return held;
}

int main(int argc, char **argv)
{
	static char buf[1 << 20];
	struct io_uring_sqe *sqe;
	struct io_uring_cqe *cqe;
	struct io_uring ring;
	char bigpath[512];
	int fda, fdb, i, ret, open_at_close = 0;
	double t0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <dir>\n", argv[0]);
		return 2;
	}
	snprintf(lockpath, sizeof(lockpath), "%s/fput.lock", argv[1]);
	snprintf(bigpath, sizeof(bigpath), "%s/fput.big", argv[1]);
	close(open(lockpath, O_CREAT | O_RDWR, 0644));

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

	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_close(sqe, fda);
	sqe->user_data = 1;
	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_fsync(sqe, fdb, 0);
	sqe->user_data = 2;

	t0 = now_ms();
	ret = io_uring_submit(&ring);		/* one io_uring_enter() */
	printf("%-16s %6.1f ms\n", "enter returned", now_ms() - t0);
	if (ret != 2) {
		fprintf(stderr, "submit %d\n", ret);
		return 1;
	}
	for (i = 0; i < 2; i++) {
		if (io_uring_wait_cqe(&ring, &cqe))
			return 1;
		if (cqe->res < 0)
			fprintf(stderr, "op %llu: %s\n", cqe->user_data,
				strerror(-cqe->res));
		if (cqe->user_data == 1)
			open_at_close = observe("CLOSE CQE", now_ms() - t0);
		else
			observe("FSYNC CQE", now_ms() - t0);
		io_uring_cqe_seen(&ring, cqe);
	}

	printf("RESULT %s\n", open_at_close ?
	       "CLOSE_CQE_SEEN_BUT_FILE_OPEN" : "FILE_CLOSED_AT_CLOSE_CQE");
	close(fdb);
	unlink(bigpath);
	return 0;
}
