/* AFL++ custom mutator: grammar-aware mutation of shell scripts.
 *
 * A thin shim: the mutation engine is tools/fuzz/gram.lua, run as a helper process
 * (curse's luajit + curse's own parser and unparser) and fed over a pipe. The helper is
 * a separate process so that nothing the engine loads (curse's runtime) lives inside
 * afl-fuzz, and so that a parser hang or crash on some input costs one respawn, not the
 * campaign: every request has a deadline, and an input that makes the parser hang or die
 * is saved to $GRAM_HANGS (a parser bug worth a look) before the helper is restarted.
 *
 * AFL++ entry points: init / fuzz / fuzz_count / splice_optional / describe / deinit.
 * No post_process: every executed input, havoc's included, stays byte-for-byte what AFL
 * stores in the queue (the harness, not the mutator, is what keeps runs safe).
 *
 * Env: GRAM_LUAJIT (the luajit binary), GRAM_ROOT (the source tree: lua/, tools/fuzz/),
 *      GRAM_COUNT (custom mutations per queue entry, default 2048 -- AFL's own havoc runs
 *      as well unless AFL_CUSTOM_MUTATOR_ONLY=1), GRAM_STATS (engine stats file),
 *      GRAM_HANGS (directory for inputs the engine hangs/dies on), GRAM_TIMEOUT_MS (1000). */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef GRAM_DEFAULT_LUAJIT
#define GRAM_DEFAULT_LUAJIT "luajit"
#endif
#ifndef GRAM_DEFAULT_ROOT
#define GRAM_DEFAULT_ROOT "."
#endif

typedef struct {
  pid_t pid;
  int to, from;
  uint8_t *out;
  size_t outcap;
  char desc[256];
  uint64_t rng;
  unsigned count, timeout_ms, respawns;
  const char *hangs;
} gram_t;

static uint64_t next_rand(gram_t *g)
{
  g->rng ^= g->rng << 13; g->rng ^= g->rng >> 7; g->rng ^= g->rng << 17;
  return g->rng;
}

static void helper_stop(gram_t *g)
{
  if (g->to >= 0) close(g->to);
  if (g->from >= 0) close(g->from);
  g->to = g->from = -1;
  if (g->pid > 0) {
    int st;
    kill(g->pid, SIGKILL);
    while (waitpid(g->pid, &st, 0) < 0 && errno == EINTR);
  }
  g->pid = -1;
}

static int helper_start(gram_t *g)
{
  int a[2], b[2];
  const char *lj = getenv("GRAM_LUAJIT"), *root = getenv("GRAM_ROOT");
  char script[4096];
  if (!lj) lj = GRAM_DEFAULT_LUAJIT;
  if (!root) root = GRAM_DEFAULT_ROOT;
  snprintf(script, sizeof script, "%s/tools/fuzz/gram.lua", root);
  if (pipe2(a, O_CLOEXEC) || pipe2(b, O_CLOEXEC)) return -1;
  g->pid = fork();
  if (g->pid < 0) return -1;
  if (g->pid == 0) {
    dup2(a[0], 0);
    dup2(b[1], 1);
    execlp(lj, lj, script, root, (char *)0);
    _exit(127);
  }
  close(a[0]); close(b[1]);
  g->to = a[1]; g->from = b[0];
  return 0;
}

static int write_all(int fd, const void *p, size_t n)
{
  const char *c = p;
  while (n) {
    ssize_t w = write(fd, c, n);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    c += w; n -= (size_t)w;
  }
  return 0;
}

/* read exactly n bytes before the deadline (ms since the epoch of CLOCK_MONOTONIC) */
static long long now_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int read_all(int fd, void *p, size_t n, long long deadline)
{
  char *c = p;
  while (n) {
    struct pollfd pf = { fd, POLLIN, 0 };
    long long left = deadline - now_ms();
    int r;
    if (left <= 0) return -1;
    r = poll(&pf, 1, (int)left);
    if (r < 0) { if (errno == EINTR) continue; return -1; }
    if (r == 0) return -1;
    {
      ssize_t k = read(fd, c, n);
      if (k < 0) { if (errno == EINTR) continue; return -1; }
      if (k == 0) return -1;
      c += k; n -= (size_t)k;
    }
  }
  return 0;
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static void save_hang(gram_t *g, const uint8_t *buf, size_t n)
{
  char path[4200];
  int fd;
  if (!g->hangs) return;
  snprintf(path, sizeof path, "%s/engine-%u-%zu", g->hangs, g->respawns, n);
  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd >= 0) { (void)!write(fd, buf, n); close(fd); }
}

void *afl_custom_init(void *afl, unsigned int seed)
{
  gram_t *g = calloc(1, sizeof *g);
  const char *c = getenv("GRAM_COUNT"), *t = getenv("GRAM_TIMEOUT_MS");
  (void)afl;
  if (!g) return NULL;
  g->to = g->from = g->pid = -1;
  g->rng = 0x9E3779B97F4A7C15ull ^ seed;
  g->count = c ? (unsigned)atoi(c) : 2048;
  g->timeout_ms = t ? (unsigned)atoi(t) : 1000;
  g->hangs = getenv("GRAM_HANGS");
  signal(SIGPIPE, SIG_IGN);
  if (helper_start(g)) { free(g); return NULL; }
  return g;
}

uint32_t afl_custom_fuzz_count(void *data, const uint8_t *buf, size_t buf_size)
{
  (void)buf; (void)buf_size;
  return ((gram_t *)data)->count;
}

/* AFL passes a splice partner (add_buf) on every call when this says so: the engine uses
 * it for subtree splicing across queue entries. */
uint32_t afl_custom_splice_optional(void *data)
{
  (void)data;
  return 1;
}

size_t afl_custom_fuzz(void *data, uint8_t *buf, size_t buf_size, uint8_t **out_buf,
                       uint8_t *add_buf, size_t add_buf_size, size_t max_size)
{
  gram_t *g = data;
  uint8_t h[13], l4[4], dl;
  uint32_t n;
  long long deadline;
  if (buf_size > (1u << 20)) buf_size = 1u << 20;
  if (!add_buf) add_buf_size = 0;
  if (add_buf_size > (1u << 20)) add_buf_size = 1u << 20;
  if (g->pid < 0 && helper_start(g)) return 0;
  h[0] = 'M';
  put32(h + 1, (uint32_t)next_rand(g));
  put32(h + 5, (uint32_t)(max_size > 0xffffffffu ? 0xffffffffu : max_size));
  put32(h + 9, (uint32_t)buf_size);
  put32(l4, (uint32_t)add_buf_size);
  if (write_all(g->to, h, 13) || write_all(g->to, buf, buf_size) || write_all(g->to, l4, 4) ||
      write_all(g->to, add_buf, add_buf_size))
    goto fail;
  deadline = now_ms() + g->timeout_ms;
  if (read_all(g->from, l4, 4, deadline)) goto fail;
  n = get32(l4);
  if (n > max_size || n > (64u << 20)) goto fail;
  if (n + 1 > g->outcap) {
    uint8_t *o = realloc(g->out, n + 1);
    if (!o) goto fail;
    g->out = o; g->outcap = n + 1;
  }
  if (read_all(g->from, g->out, n, deadline) || read_all(g->from, &dl, 1, deadline)) goto fail;
  if (read_all(g->from, g->desc, dl, deadline)) goto fail;
  g->desc[dl] = 0;
  *out_buf = g->out;
  return n;
fail:
  save_hang(g, buf, buf_size);
  g->respawns++;
  helper_stop(g);
  helper_start(g);
  strcpy(g->desc, "gram-respawn");
  return 0;
}

const char *afl_custom_describe(void *data, size_t max_description_len)
{
  gram_t *g = data;
  if (strlen(g->desc) >= max_description_len) g->desc[max_description_len - 1] = 0;
  return g->desc;
}

void afl_custom_deinit(void *data)
{
  gram_t *g = data;
  helper_stop(g);
  free(g->out);
  free(g);
}
