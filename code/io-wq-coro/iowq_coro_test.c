// SPDX-License-Identifier: GPL-2.0
/*
 * Tests for io-wq coroutine mode (kernel.io_uring_wq_coro). Each test must
 * pass with the sysctl off and on.
 *
 *   iowq_coro_test <dir-on-ext4> [test]
 *
 * T1 fs:      openat(O_CREAT)/write/fsync/statx/renameat/unlinkat batches
 * T2 pingpong: async read on an empty pipe, then async write to it: the
 *             reader must be woken by the writer (same worker in coro mode)
 * T3 many:    32 async reads block on 32 pipes; count io-wq workers; then
 *             write the pipes in reverse order, all reads must complete
 * T4 lock:    write + ftruncate + ftruncate + fsync on one file, in rounds:
 *             i_rwsem is taken by ops that sleep while holding it
 * T5 cancel:  cancel one of 8 blocked pipe reads, the other 7 still work
 * T6 exit:    a child exits with 16 blocked async reads, must not hang
 * T7 samelock: an async write faults on a userfaultfd page while holding the
 *             file's i_rwsem; an async ftruncate of the same file then waits
 *             for that i_rwsem, owned by the same worker task in coro mode.
 *             Resolving the fault must let both finish.
 * T8 cancelrace: 16 blocked pipe reads per round; wake half of them by
 *             writing while canceling the other half. Only canceled reads may
 *             fail: a cancel must not interrupt another request that shares
 *             the worker task.
 * T9 fifo:    200 async FIFO opens really sleep in io-wq (more than one
 *             worker's coroutines); writers open them in reverse order; every
 *             open must return a valid fd
 */
#define _GNU_SOURCE
#include <liburing.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <poll.h>
#include <linux/userfaultfd.h>
#include <time.h>
#include <unistd.h>

static const char *dir;
static int failed;

#define FAIL(...) do { printf("  FAIL: " __VA_ARGS__); printf("\n"); failed = 1; return -1; } while (0)

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int nr_iowq_workers(void)
{
	char path[64], comm[64];
	struct dirent *d;
	int nr = 0;
	DIR *td = opendir("/proc/self/task");

	while (td && (d = readdir(td))) {
		FILE *f;

		if (d->d_name[0] == '.')
			continue;
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

/* wait for @nr completions within @secs, res[user_data] = cqe->res */
static int wait_cqes(struct io_uring *ring, int nr, int *res, int max_ud,
		     double secs)
{
	double end = now() + secs;

	while (nr > 0) {
		struct __kernel_timespec ts = { .tv_nsec = 100000000 };
		struct io_uring_cqe *cqe;
		int ret = io_uring_wait_cqe_timeout(ring, &cqe, &ts);

		if (ret == -ETIME || ret == -EINTR) {
			if (now() > end)
				return -ETIME;
			continue;
		}
		if (ret)
			return ret;
		if (cqe->user_data < (unsigned)max_ud)
			res[cqe->user_data] = cqe->res;
		io_uring_cqe_seen(ring, cqe);
		nr--;
	}
	return 0;
}

static struct io_uring_sqe *get_sqe(struct io_uring *ring, unsigned ud,
				    unsigned flags)
{
	struct io_uring_sqe *sqe = io_uring_get_sqe(ring);

	if (!sqe) {
		io_uring_submit(ring);
		sqe = io_uring_get_sqe(ring);
	}
	return sqe;
}

#define NF	64

static int t1_fs(void)
{
	char name[NF][256], name2[NF][256];
	static char buf[NF][4096];
	int fds[NF], res[NF], i, ret;
	struct io_uring ring;
	struct statx stx[NF];

	io_uring_queue_init(256, &ring, 0);
	for (i = 0; i < NF; i++) {
		snprintf(name[i], 256, "%s/t1-%d", dir, i);
		snprintf(name2[i], 256, "%s/t1-%d.renamed", dir, i);
		unlink(name[i]);
		unlink(name2[i]);
		memset(buf[i], 'a' + i % 26, sizeof(buf[i]));
	}
	/* openat O_CREAT: force-async */
	for (i = 0; i < NF; i++) {
		struct io_uring_sqe *sqe = get_sqe(&ring, i, 0);

		io_uring_prep_openat(sqe, AT_FDCWD, name[i],
				     O_CREAT | O_RDWR | O_TRUNC, 0644);
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	if (wait_cqes(&ring, NF, res, NF, 30))
		FAIL("T1 openat timeout");
	for (i = 0; i < NF; i++) {
		if (res[i] < 0)
			FAIL("T1 openat %d: %d", i, res[i]);
		fds[i] = res[i];
	}
	/* async write, then fsync linked behind it */
	for (i = 0; i < NF; i++) {
		struct io_uring_sqe *sqe = get_sqe(&ring, i, 0);

		io_uring_prep_write(sqe, fds[i], buf[i], sizeof(buf[i]), 0);
		sqe->flags |= IOSQE_ASYNC | IOSQE_IO_LINK;
		sqe->user_data = 1000;
		sqe = get_sqe(&ring, i, 0);
		io_uring_prep_fsync(sqe, fds[i], 0);
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	if (wait_cqes(&ring, 2 * NF, res, NF, 60))
		FAIL("T1 write+fsync timeout");
	for (i = 0; i < NF; i++)
		if (res[i] < 0)
			FAIL("T1 fsync %d: %d", i, res[i]);
	/* statx */
	for (i = 0; i < NF; i++) {
		struct io_uring_sqe *sqe = get_sqe(&ring, i, 0);

		io_uring_prep_statx(sqe, AT_FDCWD, name[i], 0, STATX_SIZE, &stx[i]);
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	if (wait_cqes(&ring, NF, res, NF, 30))
		FAIL("T1 statx timeout");
	for (i = 0; i < NF; i++)
		if (res[i] < 0 || stx[i].stx_size != sizeof(buf[i]))
			FAIL("T1 statx %d: res %d size %llu", i, res[i],
			     (unsigned long long)stx[i].stx_size);
	/* rename, then unlink */
	for (i = 0; i < NF; i++) {
		struct io_uring_sqe *sqe = get_sqe(&ring, i, 0);

		io_uring_prep_renameat(sqe, AT_FDCWD, name[i], AT_FDCWD,
				       name2[i], 0);
		sqe->flags |= IOSQE_IO_LINK;
		sqe->user_data = 1000;
		sqe = get_sqe(&ring, i, 0);
		io_uring_prep_unlinkat(sqe, AT_FDCWD, name2[i], 0);
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	if (wait_cqes(&ring, 2 * NF, res, NF, 30))
		FAIL("T1 rename+unlink timeout");
	for (i = 0; i < NF; i++) {
		struct stat st;
		char check[4096];

		if (res[i] < 0)
			FAIL("T1 unlink %d: %d", i, res[i]);
		if (!stat(name[i], &st) || !stat(name2[i], &st))
			FAIL("T1 file %d still exists", i);
		ret = pread(fds[i], check, sizeof(check), 0);
		if (ret != sizeof(check) || memcmp(check, buf[i], sizeof(check)))
			FAIL("T1 data %d mismatch (%d)", i, ret);
		close(fds[i]);
	}
	io_uring_queue_exit(&ring);
	return 0;
}

static int t2_pingpong(void)
{
	struct io_uring ring;
	int p[2], res[2] = { -1, -1 }, round;
	char in[64], out[64];

	io_uring_queue_init(8, &ring, 0);
	if (pipe(p))
		FAIL("T2 pipe");
	for (round = 0; round < 200; round++) {
		struct io_uring_sqe *sqe;

		snprintf(out, sizeof(out), "ping-%d", round);
		memset(in, 0, sizeof(in));
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_read(sqe, p[0], in, sizeof(in), 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = 0;
		io_uring_submit(&ring);
		if (round & 1)
			usleep(1000);	/* let the reader sleep first */
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_write(sqe, p[1], out, strlen(out), 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = 1;
		io_uring_submit(&ring);
		if (wait_cqes(&ring, 2, res, 2, 10))
			FAIL("T2 round %d timeout (read %d write %d)", round,
			     res[0], res[1]);
		if (res[0] != (int)strlen(out) || res[1] != (int)strlen(out) ||
		    strcmp(in, out))
			FAIL("T2 round %d: read %d write %d '%s'", round,
			     res[0], res[1], in);
	}
	close(p[0]);
	close(p[1]);
	io_uring_queue_exit(&ring);
	return 0;
}

#define NP	32

static int t3_many(int *workers)
{
	int p[NP][2], res[NP], i;
	char in[NP][32], out[32];
	struct io_uring ring;

	io_uring_queue_init(64, &ring, 0);
	for (i = 0; i < NP; i++) {
		struct io_uring_sqe *sqe;

		if (pipe(p[i]))
			FAIL("T3 pipe");
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_read(sqe, p[i][0], in[i], sizeof(in[i]), 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	usleep(300000);
	*workers = nr_iowq_workers();
	for (i = NP - 1; i >= 0; i--) {
		snprintf(out, sizeof(out), "pipe-%d", i);
		if (write(p[i][1], out, strlen(out) + 1) < 0)
			FAIL("T3 write");
	}
	if (wait_cqes(&ring, NP, res, NP, 10))
		FAIL("T3 timeout");
	for (i = 0; i < NP; i++) {
		snprintf(out, sizeof(out), "pipe-%d", i);
		if (res[i] != (int)strlen(out) + 1 || strcmp(in[i], out))
			FAIL("T3 read %d: %d '%s'", i, res[i], in[i]);
		close(p[i][0]);
		close(p[i][1]);
	}
	io_uring_queue_exit(&ring);
	return 0;
}

static int t4_lock(void)
{
	static char buf[1 << 20];
	struct io_uring ring;
	char name[256];
	int fd, round, res[4];

	snprintf(name, sizeof(name), "%s/t4", dir);
	fd = open(name, O_CREAT | O_RDWR | O_TRUNC, 0644);
	if (fd < 0)
		FAIL("T4 open");
	memset(buf, 'x', sizeof(buf));
	io_uring_queue_init(16, &ring, 0);
	for (round = 0; round < 100; round++) {
		struct io_uring_sqe *sqe;

		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_write(sqe, fd, buf, sizeof(buf), 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = 0;
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_ftruncate(sqe, fd, 4096 * (round % 7));
		sqe->user_data = 1;
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_ftruncate(sqe, fd, 8192 * (round % 5));
		sqe->user_data = 2;
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_fsync(sqe, fd, 0);
		sqe->user_data = 3;
		io_uring_submit(&ring);
		if (wait_cqes(&ring, 4, res, 4, 30))
			FAIL("T4 round %d timeout", round);
		if (res[0] != sizeof(buf) || res[1] || res[2] || res[3])
			FAIL("T4 round %d: %d %d %d %d", round, res[0], res[1],
			     res[2], res[3]);
	}
	close(fd);
	unlink(name);
	io_uring_queue_exit(&ring);
	return 0;
}

static int t5_cancel(void)
{
	int p[8][2], res[16], i;
	char in[8][16];
	struct io_uring ring;
	struct io_uring_sqe *sqe;

	io_uring_queue_init(32, &ring, 0);
	for (i = 0; i < 8; i++) {
		if (pipe(p[i]))
			FAIL("T5 pipe");
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_read(sqe, p[i][0], in[i], sizeof(in[i]), 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	usleep(200000);
	sqe = io_uring_get_sqe(&ring);
	io_uring_prep_cancel64(sqe, 3, 0);
	sqe->user_data = 8;
	io_uring_submit(&ring);
	/* the canceled read and the cancel request */
	memset(res, 0x7f, sizeof(res));
	if (wait_cqes(&ring, 2, res, 16, 10))
		FAIL("T5 cancel timeout");
	if (res[3] != -ECANCELED && res[3] != -EINTR)
		FAIL("T5 canceled read: %d", res[3]);
	if (res[8] != 0 && res[8] != -EALREADY)
		FAIL("T5 cancel result: %d", res[8]);
	for (i = 0; i < 8; i++)
		if (i != 3 && write(p[i][1], "x", 1) != 1)
			FAIL("T5 write");
	if (wait_cqes(&ring, 7, res, 16, 10))
		FAIL("T5 remaining reads timeout");
	for (i = 0; i < 8; i++) {
		if (i != 3 && res[i] != 1)
			FAIL("T5 read %d: %d", i, res[i]);
		close(p[i][0]);
		close(p[i][1]);
	}
	io_uring_queue_exit(&ring);
	return 0;
}

static int t6_exit(void)
{
	double start = now();
	int status;
	pid_t pid = fork();

	if (!pid) {
		struct io_uring ring;
		int p[16][2], i;
		static char in[16][8];

		io_uring_queue_init(32, &ring, 0);
		for (i = 0; i < 16; i++) {
			struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);

			if (pipe(p[i]))
				_exit(2);
			io_uring_prep_read(sqe, p[i][0], in[i], sizeof(in[i]), 0);
			sqe->flags |= IOSQE_ASYNC;
		}
		io_uring_submit(&ring);
		usleep(200000);
		_exit(0);
	}
	while (waitpid(pid, &status, WNOHANG) == 0) {
		if (now() - start > 15) {
			kill(pid, SIGKILL);
			FAIL("T6 child with blocked reads did not exit in 15s");
		}
		usleep(50000);
	}
	if (!WIFEXITED(status) || WEXITSTATUS(status))
		FAIL("T6 child status 0x%x", status);
	return 0;
}

static int t7_samelock(void)
{
	long psz = sysconf(_SC_PAGESIZE);
	struct uffdio_api api = { .api = UFFD_API };
	struct uffdio_register reg = { .mode = UFFDIO_REGISTER_MODE_MISSING };
	struct io_uring ring;
	struct io_uring_sqe *sqe;
	char name[256], *area, *page, check[64];
	int uffd, fd, res[2] = { -99, -99 }, round;

	uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);
	if (uffd < 0 || ioctl(uffd, UFFDIO_API, &api))
		FAIL("T7 userfaultfd: %m");
	page = aligned_alloc(psz, psz);
	io_uring_queue_init(8, &ring, 0);
	snprintf(name, sizeof(name), "%s/t7", dir);

	for (round = 0; round < 20; round++) {
		struct uffdio_copy copy = { 0 };
		struct uffd_msg msg;
		struct pollfd pfd = { .fd = uffd, .events = POLLIN };

		area = mmap(NULL, psz, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		reg.range.start = (unsigned long)area;
		reg.range.len = psz;
		if (ioctl(uffd, UFFDIO_REGISTER, &reg))
			FAIL("T7 register: %m");
		fd = open(name, O_CREAT | O_RDWR | O_TRUNC, 0644);

		/* holds i_rwsem, then faults on area and sleeps */
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_write(sqe, fd, area, 64, 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = 0;
		io_uring_submit(&ring);
		if (poll(&pfd, 1, 5000) != 1)
			FAIL("T7 round %d: write did not fault", round);

		/* waits for the same i_rwsem */
		sqe = io_uring_get_sqe(&ring);
		io_uring_prep_ftruncate(sqe, fd, 32);
		sqe->user_data = 1;
		io_uring_submit(&ring);
		usleep(100000);

		/* resolve the fault: the write goes on, then the ftruncate */
		if (read(uffd, &msg, sizeof(msg)) != sizeof(msg) ||
		    msg.event != UFFD_EVENT_PAGEFAULT)
			FAIL("T7 round %d: uffd msg", round);
		snprintf(page, psz, "round-%02d-data-from-uffd", round);
		copy.src = (unsigned long)page;
		copy.dst = msg.arg.pagefault.address & ~(psz - 1);
		copy.len = psz;
		if (ioctl(uffd, UFFDIO_COPY, &copy))
			FAIL("T7 round %d: UFFDIO_COPY: %m", round);

		res[0] = res[1] = -99;
		if (wait_cqes(&ring, 2, res, 2, 10))
			FAIL("T7 round %d timeout: write %d ftruncate %d", round,
			     res[0], res[1]);
		if (res[0] != 64 || res[1] != 0)
			FAIL("T7 round %d: write %d ftruncate %d", round,
			     res[0], res[1]);
		/* ftruncate ran after the write: 32 bytes of the new data */
		memset(check, 0, sizeof(check));
		if (pread(fd, check, sizeof(check), 0) != 32 ||
		    memcmp(check, page, 32))
			FAIL("T7 round %d: content '%.32s'", round, check);
		close(fd);
		munmap(area, psz);
	}
	unlink(name);
	close(uffd);
	free(page);
	io_uring_queue_exit(&ring);
	return 0;
}

static int t8_cancelrace(void)
{
	int p[16][2], res[32], round, i, bad = 0;
	char in[16][8];
	struct io_uring ring;
	struct io_uring_sqe *sqe;

	io_uring_queue_init(64, &ring, 0);
	for (i = 0; i < 16; i++)
		if (pipe(p[i]))
			FAIL("T8 pipe");
	for (round = 0; round < 100; round++) {
		for (i = 0; i < 16; i++) {
			sqe = io_uring_get_sqe(&ring);
			io_uring_prep_read(sqe, p[i][0], in[i], sizeof(in[i]), 0);
			sqe->flags |= IOSQE_ASYNC;
			sqe->user_data = i;
		}
		io_uring_submit(&ring);
		usleep(2000);
		/* even: wake by data, odd: cancel, interleaved */
		for (i = 0; i < 16; i += 2) {
			if (write(p[i][1], "x", 1) != 1)
				FAIL("T8 write");
			sqe = io_uring_get_sqe(&ring);
			io_uring_prep_cancel64(sqe, i + 1, 0);
			sqe->user_data = 16 + i + 1;
			io_uring_submit(&ring);
		}
		memset(res, 0x7f, sizeof(res));
		if (wait_cqes(&ring, 16 + 8, res, 32, 10))
			FAIL("T8 round %d timeout", round);
		for (i = 0; i < 16; i += 2)
			if (res[i] != 1) {
				printf("  T8 round %d: woken read %d got %d\n",
				       round, i, res[i]);
				bad++;
			}
		for (i = 1; i < 16; i += 2)
			if (res[i] != -ECANCELED && res[i] != -EINTR && res[i] != 1)
				FAIL("T8 round %d: canceled read %d got %d", round,
				     i, res[i]);
		/* a read that won the race against its cancel consumed nothing */
	}
	for (i = 0; i < 16; i++) {
		close(p[i][0]);
		close(p[i][1]);
	}
	io_uring_queue_exit(&ring);
	if (bad)
		FAIL("T8 %d innocent reads failed", bad);
	return 0;
}

#define NFIFO	200

static int t9_fifo(int *workers)
{
	static char path[NFIFO][300];
	int res[NFIFO], wfd[NFIFO], i;
	struct io_uring ring;

	io_uring_queue_init(256, &ring, 0);
	for (i = 0; i < NFIFO; i++) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);

		snprintf(path[i], sizeof(path[i]), "%s/t9-fifo-%d", dir, i);
		unlink(path[i]);
		if (mkfifo(path[i], 0600))
			FAIL("T9 mkfifo");
		io_uring_prep_openat(sqe, AT_FDCWD, path[i], O_RDONLY, 0);
		sqe->flags |= IOSQE_ASYNC;
		sqe->user_data = i;
	}
	io_uring_submit(&ring);
	usleep(500000);
	*workers = nr_iowq_workers();
	/*
	 * Writers in reverse order. Normal io-wq may not have started every
	 * open yet (max_workers): ENXIO means no reader yet, retry later.
	 */
	memset(res, 0xff, sizeof(res));
	for (i = 0; i < NFIFO; i++)
		wfd[i] = -1;
	{
		int left = NFIFO, got = 0;
		double end = now() + 20;

		while (got < NFIFO) {
			struct io_uring_cqe *cqe;

			for (i = NFIFO - 1; left && i >= 0; i--) {
				if (wfd[i] >= 0)
					continue;
				wfd[i] = open(path[i], O_WRONLY | O_NONBLOCK);
				if (wfd[i] >= 0)
					left--;
				else if (errno != ENXIO)
					FAIL("T9 writer open %d: %m", i);
			}
			while (!io_uring_peek_cqe(&ring, &cqe)) {
				res[cqe->user_data] = cqe->res;
				io_uring_cqe_seen(&ring, cqe);
				got++;
			}
			if (now() > end)
				FAIL("T9 timeout: %d of %d opens done", got, NFIFO);
			usleep(1000);
		}
	}
	for (i = 0; i < NFIFO; i++) {
		struct stat st;

		if (res[i] < 0 || fstat(res[i], &st) || !S_ISFIFO(st.st_mode))
			FAIL("T9 open %d: %d", i, res[i]);
		close(res[i]);
		close(wfd[i]);
		unlink(path[i]);
	}
	io_uring_queue_exit(&ring);
	return 0;
}

int main(int argc, char **argv)
{
	const char *only = argc > 2 ? argv[2] : NULL;
	int workers = -1;

	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc < 2) {
		fprintf(stderr, "usage: %s <dir> [T1..T7]\n", argv[0]);
		return 2;
	}
	dir = argv[1];
#define RUN(n, call) do {						\
	if (!only || !strcmp(only, n)) {				\
		double t = now();					\
		int r = call;						\
		printf("%s %s (%.2fs)\n", r ? "not ok" : "ok", n, now() - t); \
	}								\
} while (0)
	RUN("T1", t1_fs());
	RUN("T2", t2_pingpong());
	RUN("T3", t3_many(&workers));
	if (workers >= 0)
		printf("# T3 io-wq workers with %d blocked reads: %d\n", NP, workers);
	RUN("T4", t4_lock());
	RUN("T5", t5_cancel());
	RUN("T6", t6_exit());
	RUN("T7", t7_samelock());
	RUN("T8", t8_cancelrace());
	{
		int w9 = -1;

		RUN("T9", t9_fifo(&w9));
		if (w9 >= 0)
			printf("# T9 io-wq workers with %d blocked FIFO opens: %d\n", NFIFO, w9);
	}
	return failed;
}
