#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint64_t parse_size(const char *s)
{
	char *end = NULL;
	uint64_t value;

	errno = 0;
	value = strtoull(s, &end, 0);
	if (errno || end == s) {
		fprintf(stderr, "invalid size: %s\n", s);
		exit(2);
	}
	if (*end == 'G' || *end == 'g')
		value *= 1024ULL * 1024ULL * 1024ULL;
	else if (*end == 'M' || *end == 'm')
		value *= 1024ULL * 1024ULL;
	else if (*end == 'K' || *end == 'k')
		value *= 1024ULL;
	else if (*end) {
		fprintf(stderr, "invalid size suffix: %s\n", s);
		exit(2);
	}
	return value;
}

static void write_marker(const char *path, const char *msg)
{
	int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);

	if (fd < 0) {
		perror(path);
		exit(3);
	}
	if (write(fd, msg, strlen(msg)) < 0) {
		perror("write marker");
		exit(3);
	}
	close(fd);
}

int main(int argc, char **argv)
{
	const long page = sysconf(_SC_PAGESIZE);
	const char *ready_path;
	const char *go_path;
	const char *done_path;
	uint64_t bytes;
	uint64_t max_wait_ms;
	uint64_t start;
	volatile uint8_t *buf;
	volatile uint64_t spin = 1;
	uint64_t sum = 0;
	char done_msg[256];

	if (argc != 6) {
		fprintf(stderr,
			"usage: %s <bytes> <ready> <go> <done> <max_wait_sec>\n",
			argv[0]);
		return 2;
	}

	bytes = parse_size(argv[1]);
	ready_path = argv[2];
	go_path = argv[3];
	done_path = argv[4];
	max_wait_ms = strtoull(argv[5], NULL, 0) * 1000ULL;
	if (!bytes || page <= 0 || bytes % (uint64_t)page) {
		fprintf(stderr, "bytes must be page-aligned and nonzero\n");
		return 2;
	}

	buf = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	madvise((void *)buf, bytes, MADV_NOHUGEPAGE);

	for (uint64_t off = 0; off < bytes; off += (uint64_t)page)
		buf[off] = (uint8_t)(off >> 12);

	snprintf(done_msg, sizeof(done_msg),
		 "allocated_bytes=%" PRIu64 "\npages=%" PRIu64 "\n",
		 bytes, bytes / (uint64_t)page);
	write_marker(ready_path, done_msg);

	start = now_ms();
	while (access(go_path, F_OK) != 0) {
		for (int i = 0; i < 1000000; i++)
			spin = spin * 1103515245ULL + 12345ULL + (uint64_t)i;
		sched_yield();
		if (now_ms() - start > max_wait_ms) {
			fprintf(stderr, "timed out waiting for go marker\n");
			return 4;
		}
	}

	for (uint64_t off = 0; off < bytes; off += (uint64_t)page)
		sum += buf[off];

	snprintf(done_msg, sizeof(done_msg),
		 "sweep_sum=%" PRIu64 "\nspin=%" PRIu64 "\n", sum, spin);
	write_marker(done_path, done_msg);
	return 0;
}
