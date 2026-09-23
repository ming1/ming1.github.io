// SPDX-License-Identifier: GPL-2.0
/*
 * io-wq coroutine mode benchmark: ops/s, CPU and io-wq worker count.
 *
 *   iowq_coro_bench <dir-on-ext4> <statx|dsync|pipe> <qd> <secs>
 *
 * statx: statx of a cached file, punted to io-wq, never blocks
 * dsync: 4K write with RWF_DSYNC via io-wq, always blocks on the device
 * pipe:  async read on a pipe then async write to it, cross-request wakeup
 *
 *   iowq_coro_bench <dir> longwait <N> <hold-ms>
 *
 * longwait: N async FIFO opens (O_RDONLY) block in io-wq for hold-ms, then
 *           writers open the FIFOs; reports io-wq workers while blocked and
 *           time until all opens complete
 */
#define _GNU_SOURCE
#include <liburing.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double cpu_secs(void)
{
	struct rusage ru;

	getrusage(RUSAGE_SELF, &ru);
	return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 +
	       ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static int nr_workers(void)
{
	char path[300], comm[64];
	struct dirent *d;
	int nr = 0;
	DIR *td = opendir("/proc/self/task");

	while (td && (d = readdir(td))) {
		FILE *f;

		snprintf(path, sizeof(path), "/proc/self/task/%s/comm", d->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(comm, sizeof(comm), f) && !strncmp(comm, "iou-wrk-", 8))
			nr++;
		fclose(f);
	}
	if (td)
		closedir(td);
	return nr;
}

#define MAXQD	128

static int fds[MAXQD], pipes[MAXQD][2];
static char name[MAXQD][256], *bufs[MAXQD];
static struct statx stx[MAXQD];
static const char *op;

/* queue the request(s) of slot i; returns completions expected */
static int queue(struct io_uring *ring, int i)
{
	struct io_uring_sqe *sqe = io_uring_get_sqe(ring);

	if (!strcmp(op, "statx")) {
		io_uring_prep_statx(sqe, AT_FDCWD, name[i], 0, STATX_SIZE, &stx[i]);
		sqe->user_data = i;
		return 1;
	}
	if (!strcmp(op, "dsync")) {
		io_uring_prep_write(sqe, fds[i], bufs[i], 4096, 0);
		sqe->rw_flags = RWF_DSYNC;
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = i;
		return 1;
	}
	/* pipe: read first, the write wakes it */
	io_uring_prep_read(sqe, pipes[i][0], bufs[i], 64, 0);
	sqe->flags |= IOSQE_ASYNC;
	sqe->user_data = i;
	sqe = io_uring_get_sqe(ring);
	io_uring_prep_write(sqe, pipes[i][1], "0123456789abcdef", 16, 0);
	sqe->flags |= IOSQE_ASYNC;
	sqe->user_data = i | (1u << 16);
	return 2;
}

/*
 * N async opens of N FIFOs for reading: each open really sleeps in io-wq
 * (wait_for_partner(), no poll), until a writer opens the FIFO.
 */
static int longwait(const char *dir, int n, int hold_ms)
{
	struct io_uring ring;
	char (*path)[64] = calloc(n, 64);
	int *wfd = calloc(n, sizeof(int)), i, done = 0, workers;
	double t0;

	if (io_uring_queue_init(n > 4096 ? 4096 : n, &ring, 0))
		return 1;
	for (i = 0; i < n; i++) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);

		if (!sqe) {
			io_uring_submit(&ring);
			sqe = io_uring_get_sqe(&ring);
		}
		snprintf(path[i], 64, "%s/fifo-%d", dir, i);
		unlink(path[i]);
		if (mkfifo(path[i], 0600))
			return 1;
		io_uring_prep_openat(sqe, AT_FDCWD, path[i], O_RDONLY, 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	usleep(hold_ms * 1000);
	workers = nr_workers();
	t0 = now();
	for (i = 0; i < n; i++)
		wfd[i] = -1;
	/* ENXIO: that open has not started yet (io-wq max_workers), retry */
	while (done < n) {
		struct io_uring_cqe *cqe;

		for (i = 0; i < n; i++) {
			if (wfd[i] >= 0)
				continue;
			wfd[i] = open(path[i], O_WRONLY | O_NONBLOCK);
			if (wfd[i] < 0 && errno != ENXIO) {
				perror("writer open");
				return 1;
			}
		}
		while (!io_uring_peek_cqe(&ring, &cqe)) {
			if (cqe->res < 0) {
				fprintf(stderr, "open %llu: %d\n", cqe->user_data, cqe->res);
				return 1;
			}
			close(cqe->res);
			io_uring_cqe_seen(&ring, cqe);
			done++;
		}
	}
	printf("longwait n %5d: workers while blocked %5d  drain %7.1f ms\n",
	       n, workers, (now() - t0) * 1000);
	for (i = 0; i < n; i++) {
		close(wfd[i]);
		unlink(path[i]);
	}
	return 0;
}

int main(int argc, char **argv)
{
	int qd, secs, i, inflight = 0, maxw = 0;
	unsigned long ops = 0;
	int pending[MAXQD] = { 0 };
	struct io_uring ring;
	double t0, c0, t, c;

	if (argc < 5) {
		fprintf(stderr, "usage: %s <dir> <statx|dsync|pipe> <qd> <secs>\n", argv[0]);
		return 2;
	}
	op = argv[2];
	if (!strcmp(op, "longwait"))
		return longwait(argv[1], atoi(argv[3]), atoi(argv[4]));
	qd = atoi(argv[3]);
	secs = atoi(argv[4]);
	if (qd > MAXQD)
		qd = MAXQD;
	for (i = 0; i < qd; i++) {
		snprintf(name[i], sizeof(name[i]), "%s/bench-%d", argv[1], i);
		fds[i] = open(name[i], O_CREAT | O_RDWR, 0644);
		bufs[i] = aligned_alloc(4096, 4096);
		memset(bufs[i], 'b', 4096);
		if (pwrite(fds[i], bufs[i], 4096, 0) != 4096 || pipe(pipes[i]))
			return 1;
	}
	io_uring_queue_init(2 * MAXQD, &ring, 0);

	for (i = 0; i < qd; i++)
		inflight += (pending[i] = queue(&ring, i));
	io_uring_submit(&ring);

	t0 = now();
	c0 = cpu_secs();
	while ((t = now()) - t0 < secs) {
		struct io_uring_cqe *cqe;

		if (io_uring_wait_cqe(&ring, &cqe))
			break;
		i = cqe->user_data & 0xffff;
		if (cqe->res < 0) {
			fprintf(stderr, "op %s slot %d: %d\n", op, i, cqe->res);
			return 1;
		}
		io_uring_cqe_seen(&ring, cqe);
		inflight--;
		if (--pending[i] == 0) {
			ops++;
			inflight += (pending[i] = queue(&ring, i));
			io_uring_submit(&ring);
		}
		if ((ops & 1023) == 0) {
			int w = nr_workers();

			if (w > maxw)
				maxw = w;
		}
	}
	t = now() - t0;
	c = cpu_secs() - c0;
	printf("%-6s qd %3d: %9.0f ops/s  cpu %4.0f%%  workers %d\n", op, qd,
	       ops / t, 100 * c / t, maxw);
	return 0;
}
