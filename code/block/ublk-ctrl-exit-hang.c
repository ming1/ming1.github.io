// SPDX-License-Identifier: GPL-2.0
/*
 * Reproducer: io-wq runs queued work after its worker dequeued SIGKILL.
 *
 * ublk START_DEV sleeps in ublk_wait_dev_ready_and_lock() until all queues
 * are ready. It returns -EAGAIN for IO_URING_F_NONBLOCK, so io_uring runs
 * it on an io-wq worker of the task which issued it (the control task;
 * kublk issues it from the daemon's main thread, ublksrv from a separate
 * process). If that task dies while the command is queued but not yet
 * running, and the server can't make the device ready:
 *
 *   main thread                        io-wq worker (idle in schedule_timeout)
 *   submit START_DEV: enqueue, wake worker
 *   kill(SIGKILL) -> do_exit()
 *     io_uring_files_cancel()
 *       io_wq_exit_start(): EXIT set
 *       io_wq_exit_workers(): wait
 *                                      wakes: signal_pending()
 *                                        get_signal() dequeues SIGKILL
 *                                      break out of loop
 *                                      EXIT set && work queued -> drain
 *                                        START_DEV: wait, nothing pending
 *                                        -> sleeps forever
 *     -> waits for the worker forever (D state, unkillable)
 *
 * To hit the window every time, the main thread runs SCHED_FIFO pinned to
 * one CPU and the io-wq worker is pinned to the same CPU, so the worker
 * can't run until the main thread sleeps in io_wq_exit_workers().
 *
 * The device never needs a server: the hang is in the control path, and
 * the control task here is the only thing that could have become one.
 * DEL_DEV has the same shape ("del" mode): it waits for the device to be
 * freed, which needs /dev/ublkcN closed; the control task holds it itself
 * and only closes it in exit_files(), after the io-wq wait.
 */
#define _GNU_SOURCE
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/ublk_cmd.h>

#define CPU		0
#define CTRL_DEV	"/dev/ublk-control"

static int ctrl_cmd(struct io_uring *ring, int fd, __u32 cmd_op, __u32 dev_id,
		    void *buf, __u16 len, __u64 data0, bool wait)
{
	struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
	struct ublksrv_ctrl_cmd *cmd = (void *)sqe->cmd;
	struct io_uring_cqe *cqe;
	int ret;

	memset(sqe, 0, 2 * sizeof(*sqe));	/* SQE128 */
	sqe->fd = fd;
	sqe->opcode = IORING_OP_URING_CMD;
	sqe->cmd_op = cmd_op;
	cmd->dev_id = dev_id;
	cmd->queue_id = -1;
	cmd->addr = (__u64)(uintptr_t)buf;
	cmd->len = len;
	cmd->data[0] = data0;

	ret = io_uring_submit(ring);
	if (ret < 0)
		return ret;
	if (!wait)
		return 0;
	ret = io_uring_wait_cqe(ring, &cqe);
	if (ret < 0)
		return ret;
	ret = cqe->res;
	io_uring_cqe_seen(ring, cqe);
	return ret;
}

enum { DIE_RAISE, DIE_EXIT, DIE_KILL };
enum { CMD_START, CMD_DEL };

/* the control task, runs in the child; never returns on success */
static bool hold_ch;	/* keep /dev/ublkcN open in START_DEV mode too */

static void open_ch(__u32 dev_id)
{
	char path[64];

	snprintf(path, sizeof(path), "/dev/ublkc%u", dev_id);
	if (open(path, O_RDWR) < 0)
		err(1, "open %s", path);
}

static void ctrl_task(int pipe_w, bool rt, int how, int which)
{
	struct ublksrv_ctrl_dev_info info = {
		.nr_hw_queues = 1,
		.queue_depth = 4,
		.max_io_buf_bytes = 1 << 16,
		.dev_id = -1,
		.ublksrv_pid = getpid(),
	};
	struct ublk_params params = {
		.len = sizeof(params),
		.types = UBLK_PARAM_TYPE_BASIC,
		.basic = {
			.logical_bs_shift = 9,
			.physical_bs_shift = 12,
			.io_opt_shift = 12,
			.io_min_shift = 9,
			.max_sectors = (1 << 16) >> 9,
			.dev_sectors = 1 << 20,
		},
	};
	struct io_uring ring;
	cpu_set_t set;
	int fd, ret;

	CPU_ZERO(&set);
	CPU_SET(CPU, &set);
	if (sched_setaffinity(0, sizeof(set), &set))
		err(1, "sched_setaffinity");

	fd = open(CTRL_DEV, O_RDWR);
	if (fd < 0)
		err(1, "open " CTRL_DEV);
	ret = io_uring_queue_init(8, &ring, IORING_SETUP_SQE128);
	if (ret)
		errx(1, "io_uring_queue_init: %s", strerror(-ret));
	/* io-wq workers of this ring share the CPU with us */
	ret = io_uring_register_iowq_aff(&ring, sizeof(set), &set);
	if (ret)
		errx(1, "register_iowq_aff: %s", strerror(-ret));

	/* ADD_DEV and SET_PARAMS run on io-wq too: this creates the worker */
	ret = ctrl_cmd(&ring, fd, UBLK_U_CMD_ADD_DEV, -1, &info, sizeof(info),
		       0, true);
	if (ret)
		errx(1, "ADD_DEV: %s", strerror(-ret));
	ret = ctrl_cmd(&ring, fd, UBLK_U_CMD_SET_PARAMS, info.dev_id, &params,
		       sizeof(params), 0, true);
	if (ret)
		errx(1, "SET_PARAMS: %s", strerror(-ret));

	/* tell the parent which device to clean up */
	if (write(pipe_w, &info.dev_id, sizeof(info.dev_id)) != sizeof(info.dev_id))
		err(1, "write pipe");

	/*
	 * Let the worker finish SET_PARAMS and go idle in schedule_timeout().
	 * Only an idle worker dequeues SIGKILL in get_signal(); a worker still
	 * busy keeps the signal pending and START_DEV just returns -EINTR.
	 */
	usleep(20000);

	if (rt) {
		struct sched_param sp = { .sched_priority = 1 };

		if (sched_setscheduler(0, SCHED_FIFO, &sp))
			err(1, "sched_setscheduler");
	}

	/* queued to io-wq, wakes the idle worker; not waited for */
	if (which == CMD_DEL) {
		/*
		 * DEL_DEV waits until the device is freed, which needs our
		 * /dev/ublkcN closed: that happens in exit_files(), after
		 * the exiting task has waited for its io-wq workers.
		 */
		open_ch(info.dev_id);
		ret = ctrl_cmd(&ring, fd, UBLK_U_CMD_DEL_DEV, info.dev_id, NULL,
			       0, 0, false);
		if (ret)
			errx(1, "DEL_DEV submit: %s", strerror(-ret));
	} else {
		/* like kublk: the exiting task is also the server process */
		if (hold_ch)
			open_ch(info.dev_id);
		ret = ctrl_cmd(&ring, fd, UBLK_U_CMD_START_DEV, info.dev_id,
			       NULL, 0, getpid(), false);
		if (ret)
			errx(1, "START_DEV submit: %s", strerror(-ret));
	}

	/*
	 * How the task dies matters:
	 *
	 * raise:  tgkill(SIGKILL) is thread-directed. complete_signal() puts
	 *         SIGKILL on every thread's private pending set only, so once
	 *         the worker's get_signal() dequeues it nothing is pending.
	 *         This is what kublk does: raise() from a queue thread.
	 * exit:   exit_group() -> zap_other_threads(): same private SIGKILL.
	 * kill:   kill(pid, SIGKILL) is process-directed: SIGKILL also stays
	 *         in signal->shared_pending, so TIF_SIGPENDING stays set in
	 *         the worker and the wait returns -EINTR. No hang.
	 */
	switch (how) {
	case DIE_KILL:
		kill(getpid(), SIGKILL);
		break;
	case DIE_EXIT:
		_exit(0);
	default:
		raise(SIGKILL);
	}
	pause();
}

static void show_stacks(pid_t pid)
{
	char path[512], line[256];
	FILE *f;

	fprintf(stderr, "threads of %d:\n", pid);
	snprintf(path, sizeof(path),
		 "for t in /proc/%d/task/*; do "
		 "printf '  %%s %%s wchan=%%s\\n' \"$(basename $t)\" "
		 "\"$(cat $t/comm)\" \"$(cat $t/wchan)\"; "
		 "cat $t/stack 2>/dev/null | sed 's/^/      /'; done", pid);
	f = popen(path, "r");
	if (!f)
		return;
	while (fgets(line, sizeof(line), f))
		fputs(line, stderr);
	pclose(f);
}

/*
 * Issue one control command from a helper process with a timeout, so a
 * command which blocks forever doesn't take the reproducer with it.
 * Returns cqe->res, or -ETIMEDOUT.
 */
static int ctrl_cmd_timeout(__u32 cmd_op, __u32 dev_id, unsigned int secs)
{
	int status;
	pid_t pid = fork();

	if (pid < 0)
		err(1, "fork");
	if (!pid) {
		struct io_uring ring;
		int fd, ret;

		alarm(secs);
		fd = open(CTRL_DEV, O_RDWR);
		if (fd < 0)
			_exit(ENOENT);
		if (io_uring_queue_init(8, &ring, IORING_SETUP_SQE128))
			_exit(ENOMEM);
		ret = ctrl_cmd(&ring, fd, cmd_op, dev_id, NULL, 0, 0, true);
		_exit(ret < 0 ? -ret : 0);
	}
	waitpid(pid, &status, 0);
	if (WIFSIGNALED(status))
		return -ETIMEDOUT;
	return -WEXITSTATUS(status);
}

/*
 * Can another task get the stuck exit going again? With STOPPING support,
 * STOP_DEV wakes a START_DEV/END_USER_RECOVERY wait, but only if the
 * device has /dev/ublkcN open ("open" flag, or kublk).
 */
static bool exited(pid_t pid, int *status)
{
	for (int ms = 0; ms < 1000; ms += 10) {
		if (waitpid(pid, status, WNOHANG) == pid)
			return true;
		usleep(10000);
	}
	return false;
}

static bool rescue(pid_t pid, __u32 dev_id, int *status)
{
	int ret = ctrl_cmd_timeout(UBLK_U_CMD_STOP_DEV, dev_id, 3);

	fprintf(stderr, "  rescue: STOP_DEV -> %s\n",
		ret == -ETIMEDOUT ? "timed out" : strerror(-ret));
	if (exited(pid, status)) {
		fprintf(stderr, "  rescue: pid %d exited after STOP_DEV\n", pid);
		return true;
	}
	ret = ctrl_cmd_timeout(UBLK_U_CMD_DEL_DEV, dev_id, 3);
	fprintf(stderr, "  rescue: DEL_DEV -> %s\n",
		ret == -ETIMEDOUT ? "timed out" : strerror(-ret));
	if (exited(pid, status)) {
		fprintf(stderr, "  rescue: pid %d exited after DEL_DEV\n", pid);
		return true;
	}
	fprintf(stderr, "  rescue: pid %d still stuck\n", pid);
	return false;
}

static void del_dev(__u32 dev_id)
{
	struct io_uring ring;
	int fd, ret;

	fd = open(CTRL_DEV, O_RDWR);
	if (fd < 0)
		return;
	if (io_uring_queue_init(8, &ring, IORING_SETUP_SQE128))
		goto out;
	ret = ctrl_cmd(&ring, fd, UBLK_U_CMD_DEL_DEV, dev_id, NULL, 0, 0, true);
	/* -ENODEV: the child's own DEL_DEV already completed */
	if (ret && ret != -ENODEV)
		fprintf(stderr, "DEL_DEV %u: %s\n", dev_id, strerror(-ret));
	io_uring_queue_exit(&ring);
out:
	close(fd);
}

int main(int argc, char **argv)
{
	int iters = argc > 1 ? atoi(argv[1]) : 1;
	const char *mode = argc > 2 ? argv[2] : "raise";
	bool rt = true;
	int how = DIE_RAISE, which = CMD_START, hung = 0, rescued = 0;

	for (int a = 2; a < argc; a++) {
		if (!strcmp(argv[a], "nort"))
			rt = false;
		else if (!strcmp(argv[a], "kill"))
			how = DIE_KILL;
		else if (!strcmp(argv[a], "exit"))
			how = DIE_EXIT;
		else if (!strcmp(argv[a], "raise"))
			how = DIE_RAISE;
		else if (!strcmp(argv[a], "del"))
			which = CMD_DEL;
		else if (!strcmp(argv[a], "start"))
			which = CMD_START;
		else if (!strcmp(argv[a], "open"))
			hold_ch = true;
		else
			errx(1, "usage: %s [iters] [raise|exit|kill] [start|del] [open] [nort]",
			     argv[0]);
	}
	(void)mode;

	for (int i = 0; i < iters; i++) {
		int pfd[2], status;
		__u32 dev_id;
		pid_t pid;

		if (pipe(pfd))
			err(1, "pipe");
		pid = fork();
		if (pid < 0)
			err(1, "fork");
		if (!pid) {
			close(pfd[0]);
			ctrl_task(pfd[1], rt, how, which);
		}
		close(pfd[1]);
		if (read(pfd[0], &dev_id, sizeof(dev_id)) != sizeof(dev_id)) {
			waitpid(pid, &status, 0);
			errx(1, "child failed to set up the device");
		}
		close(pfd[0]);

		/* a healthy exit takes microseconds */
		for (int ms = 0; ms < 2000; ms += 10) {
			if (waitpid(pid, &status, WNOHANG) == pid)
				break;
			usleep(10000);
		}
		if (kill(pid, 0) == 0) {
			fprintf(stderr, "iter %d: pid %d stuck in exit after SIGKILL\n",
				i, pid);
			show_stacks(pid);
			hung++;
			if (rescue(pid, dev_id, &status)) {
				rescued++;
			} else {
				/* leaked on purpose: the device is pinned */
				continue;
			}
		}
		del_dev(dev_id);
	}
	printf("%s: %d/%d runs hung, %d rescued by STOP/DEL_DEV (%s%s, %s, %s)\n",
	       hung ? "REPRODUCED" : "clean", hung, iters, rescued,
	       which == CMD_DEL ? "DEL_DEV" : "START_DEV",
	       hold_ch ? "+ublkc open" : "",
	       how == DIE_KILL ? "kill" : how == DIE_EXIT ? "exit_group" : "raise",
	       rt ? "SCHED_FIFO" : "no rt");
	return hung ? 1 : 0;
}
