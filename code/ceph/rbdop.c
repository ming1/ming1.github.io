// rbdop.c -- librbd operations between CLOCK_MONOTONIC marks, for memtrace.sh.
//
//   rbdop now                                   print the CLOCK_MONOTONIC time (s.ns)
//   rbdop <conf> <pool> <image> <step>...       connect, open the image, warm it up, print
//                                               "ready <pid>", wait for a line on stdin, run the steps
// Steps:
//   base:<ms>                  idle, marked as window "base"
//   gap:<ms>                   idle, not marked
//   <name>:write:<off>:<len>   rbd_write + rbd_flush (the default cache policy, writearound,
//                              completes a write before the OSDs do; the flush waits for them)
//   <name>:read:<off>:<len>    rbd_read
// Each op prints "<name> <t_start> <t_done> <t_end>": t_end = t_done + TAIL_MS, so a window also
// holds the work the OSDs finish after the reply.  The warm-up writes 4 KiB to the image's last
// object: it takes the exclusive lock before the first mark.  Data buffers are allocated and
// filled before "ready".
//
// Build: gcc -O2 -o rbdop rbdop.c -I$SRC/src/include -L$B/lib -lrbd -lrados -Wl,-rpath,$B/lib
#include <rados/librados.h>
#include <rbd/librbd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TAIL_MS 300

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void sleep_ms(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

int main(int argc, char **argv)
{
	rados_t cluster;
	rados_ioctx_t io;
	rbd_image_t img;
	uint64_t size;
	char *buf, line[64];
	size_t max = 4 << 20;
	int i, r;

	if (argc == 2 && !strcmp(argv[1], "now")) {
		printf("%.9f\n", now());
		return 0;
	}
	if (argc < 5) {
		fprintf(stderr, "usage: rbdop now | rbdop <conf> <pool> <image> <step>...\n");
		return 1;
	}
	for (i = 4; i < argc; i++) {	// the largest op sizes the buffer
		unsigned long off, len;
		char name[32], op[8];
		if (sscanf(argv[i], "%31[^:]:%7[^:]:%lu:%lu", name, op, &off, &len) == 4 && len > max)
			max = len;
	}
	buf = malloc(max);
	for (i = 0; i < (int)max; i++)
		buf[i] = rand();
	if ((r = rados_create(&cluster, NULL)) < 0 || (r = rados_conf_read_file(cluster, argv[1])) < 0 ||
	    (r = rados_connect(cluster)) < 0 || (r = rados_ioctx_create(cluster, argv[2], &io)) < 0 ||
	    (r = rbd_open(io, argv[3], &img, NULL)) < 0 || (r = rbd_get_size(img, &size)) < 0) {
		fprintf(stderr, "setup: %s\n", strerror(-r));
		return 1;
	}
	if ((r = rbd_write(img, size - 4096, 4096, buf)) < 0 || (r = rbd_flush(img)) < 0) {
		fprintf(stderr, "warm-up write: %s\n", strerror(-r));
		return 1;
	}
	printf("ready %d\n", getpid());
	fflush(stdout);
	if (!fgets(line, sizeof(line), stdin))
		return 1;

	for (i = 4; i < argc; i++) {
		unsigned long off, len;
		char name[32], op[8];
		long ms;
		double t0, t1;

		if (sscanf(argv[i], "base:%ld", &ms) == 1) {
			t0 = now();
			sleep_ms(ms);
			printf("base %.9f %.9f %.9f\n", t0, now(), now());
			continue;
		}
		if (sscanf(argv[i], "gap:%ld", &ms) == 1) {
			sleep_ms(ms);
			continue;
		}
		if (sscanf(argv[i], "%31[^:]:%7[^:]:%lu:%lu", name, op, &off, &len) != 4) {
			fprintf(stderr, "bad step %s\n", argv[i]);
			return 1;
		}
		t0 = now();
		if (!strcmp(op, "write")) {
			r = rbd_write(img, off, len, buf);
			if (r >= 0)
				r = rbd_flush(img);
		} else {
			r = rbd_read(img, off, len, buf);
		}
		t1 = now();
		if (r < 0) {
			fprintf(stderr, "%s: %s\n", argv[i], strerror(-r));
			return 1;
		}
		sleep_ms(TAIL_MS);
		printf("%s %.9f %.9f %.9f\n", name, t0, t1, now());
		fflush(stdout);
	}
	printf("done\n");
	fflush(stdout);
	rbd_close(img);
	rados_ioctx_destroy(io);
	rados_shutdown(cluster);
	return 0;
}
