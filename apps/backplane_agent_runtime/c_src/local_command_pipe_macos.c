#define _DARWIN_C_SOURCE
#include "local_command_pipe_macos.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* All IPC is a bounded packet4 stream. Only the guardian owns child stdin.
 * The unreaped child anchors its original process group during cleanup. */
#define FRAME_MAX 65536U
#define QUEUE_MAX 262144U
#define CONTROL_RESERVE 8192U
#define CHUNK 8192U
struct queue { unsigned char bytes[QUEUE_MAX]; size_t begin, end; };
struct reader { unsigned char bytes[FRAME_MAX + 4]; size_t used; };
struct identity { pid_t parent, group, session; char start[64]; };
struct config {
  const char *token, *owner, *incarnation, *session;
  int rows, columns, timeout; size_t limit; bool exit_ack;
  char **command;
};

static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) _exit(111);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int descriptor(int fd, bool nonblocking) {
  int flags = fcntl(fd, F_GETFD), status = fcntl(fd, F_GETFL);
  if (flags < 0 || status < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC)) return -1;
  return nonblocking ? fcntl(fd, F_SETFL, status | O_NONBLOCK) : 0;
}
static int make_pipe(int fds[2]) {
  if (pipe(fds)) return -1;
  if (descriptor(fds[0], false) || descriptor(fds[1], false)) {
    close(fds[0]); close(fds[1]); return -1;
  }
  return 0;
}
static int exact_identity(pid_t pid, struct identity *id) {
  struct proc_bsdinfo info;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      info.pbi_pid != (unsigned int)pid) return -1;
  pid_t session = getsid(pid);
  if (session < 0) return -1;
  id->parent = (pid_t)info.pbi_ppid; id->group = (pid_t)info.pbi_pgid; id->session = session;
  snprintf(id->start, sizeof(id->start), "%llu:%llu",
    (unsigned long long)info.pbi_start_tvsec, (unsigned long long)info.pbi_start_tvusec);
  return 0;
}
static bool queued(const struct queue *q) { return q->end > q->begin; }
static int enqueue(struct queue *q, const void *data, size_t size, bool packet, bool control) {
  size_t needed = size + (packet ? 4 : 0), limit = control ? QUEUE_MAX : QUEUE_MAX - CONTROL_RESERVE;
  if (needed > limit || q->end - q->begin > limit - needed) return -1;
  if (q->end + needed > QUEUE_MAX) {
    memmove(q->bytes, q->bytes + q->begin, q->end - q->begin);
    q->end -= q->begin; q->begin = 0;
  }
  if (packet) {
    uint32_t length = htonl((uint32_t)size);
    memcpy(q->bytes + q->end, &length, 4); q->end += 4;
  }
  memcpy(q->bytes + q->end, data, size); q->end += size; return 0;
}
static int flush_queue(int fd, struct queue *q) {
  if (!queued(q)) return 0;
  ssize_t size = write(fd, q->bytes + q->begin, q->end - q->begin);
  if (size < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
  q->begin += (size_t)size;
  if (!queued(q)) q->begin = q->end = 0;
  return 0;
}
/* 0: incomplete, 1: packet ready, -1: malformed. */
static int packet(struct reader *r, size_t *length) {
  if (r->used < 4) return 0;
  uint32_t n; memcpy(&n, r->bytes, 4); n = ntohl(n);
  if (!n || n > FRAME_MAX) return -1;
  *length = n; return r->used >= n + 4U ? 1 : 0;
}
static void consume(struct reader *r, size_t length) {
  memmove(r->bytes, r->bytes + length + 4, r->used - length - 4);
  r->used -= length + 4;
}
/* 1: bytes received, 0: retry, -1: EOF/error. */
static int receive_bytes(int fd, struct reader *r) {
  if (r->used == sizeof(r->bytes)) return -1;
  ssize_t size = read(fd, r->bytes + r->used, sizeof(r->bytes) - r->used);
  if (size < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
  if (!size) return -1;
  r->used += (size_t)size; return 1;
}
static bool observe_exit(pid_t child, int *status) {
  siginfo_t info = {0};
  if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT)) return false;
  if (info.si_pid != child) return false;
  *status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status; return true;
}
static void flush_bounded(int fd, struct queue *q, int timeout) {
  int64_t deadline = now_ms() + timeout;
  while (queued(q) && now_ms() < deadline) {
    if (flush_queue(fd, q)) break;
    struct pollfd p = {.fd = fd, .events = POLLOUT}; (void)poll(&p, 1, 5);
  }
}
static void child_run(const struct config *config, int channel, int input[2], int output[2], int gate[2], int ready[2]) {
  close(channel); close(input[1]); close(output[0]); close(gate[1]); close(ready[0]);
  if (setsid() < 0 || dup2(input[0], 0) < 0 || dup2(output[1], 1) < 0 || dup2(output[1], 2) < 0) _exit(125);
  close(input[0]); close(output[1]);
  char byte = 'R';
  if (write(ready[1], &byte, 1) != 1) _exit(125);
  close(ready[1]);
  if (read(gate[0], &byte, 1) != 1 || byte != 'A') _exit(125);
  close(gate[0]); signal(SIGPIPE, SIG_DFL);
  execv(config->command[0], config->command); _exit(127);
}
/* Never signal a group after releasing the original child anchor. Escaped
 * sessions are outside this process-group contract and are not certified. */
/* Darwin returns EPERM for a group containing only zombies. A complete native
 * census may establish that every remaining member has already exited; EPERM
 * with any live or unobservable member remains an actual cleanup failure. */
static bool exited_group(pid_t group) {
  /* libproc does not expose zombies; KERN_PROC_PGRP does. A fixed-size full
   * snapshot fails closed when the native census exceeds its finite bound. */
  struct kinfo_proc members[512];
  size_t bytes = sizeof(members);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group};
  if (sysctl(mib, 4, members, &bytes, NULL, 0) || !bytes ||
      bytes >= sizeof(members) || bytes % sizeof(members[0])) return false;
  for (size_t i = 0; i < bytes / sizeof(members[0]); i++) {
    if (members[i].kp_eproc.e_pgid != group || members[i].kp_proc.p_stat != SZOMB) return false;
  }
  return true;
}
static int signal_group(pid_t group, int signal) {
  if (kill(-group, signal) == 0 || errno == ESRCH) return 0;
  return errno == EPERM && exited_group(group) ? 0 : -1;
}
static int cleanup(pid_t child, int timeout, int *status, const char **error) {
  int64_t start = now_ms(), deadline = start + timeout;
  bool exited = false, killed = false;
  if (signal_group(child, SIGTERM)) { *error = "term_signal"; return -1; }
  if (signal_group(child, SIGCONT)) { *error = "cont_signal"; return -1; }
  while (now_ms() < deadline) {
    exited = observe_exit(child, status);
    if (!killed && now_ms() >= start + 150) {
      if (signal_group(child, SIGKILL)) { *error = "kill_signal"; return -1; }
      killed = true;
    }
    if (exited && killed) break;
    (void)poll(NULL, 0, 5);
  }
  if (!exited || !killed) { *error = "leader_exit_unobserved"; return -1; }
  if (waitpid(child, NULL, WNOHANG) != child) { *error = "leader_reap_unobserved"; return -1; }
  while (now_ms() < deadline) {
    if (kill(-child, 0) < 0) {
      if (errno == ESRCH) return 0;
      *error = "group_observation"; return -1;
    }
    (void)poll(NULL, 0, 5);
  }
  *error = "group_absence_unconfirmed"; return -1;
}
static int output_frame(int fd, struct queue *out, size_t *bytes, const struct config *config, bool *closed) {
  unsigned char data[CHUNK + 1];
  ssize_t size = read(fd, data + 1, CHUNK);
  if (!size) { *closed = true; return 0; }
  if (size < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
  size_t accepted = config->limit ? (config->limit > *bytes ? config->limit - *bytes : 0) : (size_t)size;
  if (accepted > (size_t)size) accepted = (size_t)size;
  data[0] = 'O'; *bytes += accepted;
  if (accepted && enqueue(out, data, accepted + 1, true, false)) return -1;
  if (accepted != (size_t)size) return -2;
  return 0;
}
static void guardian(const struct config *config, int channel, pid_t broker) {
  int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
  if (null_fd < 0) _exit(111);
  for (int i = 0; i < 3; i++) if (dup2(null_fd, i) < 0) _exit(111);
  if (null_fd > 2) close(null_fd);
  int input[2], output[2], gate[2], ready[2];
  if (make_pipe(input) || make_pipe(output) || make_pipe(gate) || make_pipe(ready)) _exit(111);
  pid_t child = fork();
  if (child < 0) _exit(111);
  if (!child) child_run(config, channel, input, output, gate, ready);
  close(input[0]); close(output[1]); close(gate[0]); close(ready[1]);
  struct pollfd setup = {.fd = ready[0], .events = POLLIN}; char byte = 0;
  bool setup_ok = poll(&setup, 1, 1000) > 0 && read(ready[0], &byte, 1) == 1 && byte == 'R';
  close(ready[0]);
  struct identity b, g, c;
  bool identity_ok = exact_identity(broker, &b) == 0 && exact_identity(getpid(), &g) == 0 && exact_identity(child, &c) == 0 &&
    g.parent == broker && c.parent == getpid() && c.session == child && c.group == child;
  if (!setup_ok || !identity_ok || descriptor(input[1], true) || descriptor(output[0], true)) {
    close(gate[1]); (void)kill(child, SIGKILL);
    int status; int64_t deadline = now_ms() + 1000;
    while (!observe_exit(child, &status) && now_ms() < deadline) (void)poll(NULL, 0, 5);
    (void)waitpid(child, NULL, WNOHANG); _exit(111);
  }
  char evidence[2048], message[4096];
  int length = snprintf(evidence, sizeof(evidence), "1 %s %d %s %d %s %d %s %d %d %d %s %s %s",
    config->token, broker, b.start, getpid(), g.start, child, c.start, child,
    config->rows, config->columns, config->owner, config->incarnation, config->session);
  if (length < 0 || (size_t)length >= sizeof(evidence)) _exit(111);
  struct queue out = {0}, in = {0}; struct reader control = {0};
  message[0] = 'R'; memcpy(message + 1, evidence, (size_t)length);
  if (enqueue(&out, message, (size_t)length + 1, true, true)) _exit(111);
  bool dispatched = false, cancel = false, eof = false, output_closed = false, limited = false;
  bool channel_alive = true; size_t output_bytes = 0; int child_status = -1;
  while (!cancel) {
    if (flush_queue(channel, &out)) { channel_alive = false; break; }
    if (observe_exit(child, &child_status)) {
      length = snprintf(message, sizeof(message), "X%d", child_status);
      (void)enqueue(&out, message, (size_t)length, true, true); break;
    }
    if (eof && input[1] >= 0 && !queued(&in)) {
      if (close(input[1])) { cancel = true; break; }
      input[1] = -1;
      if (enqueue(&out, "E", 1, true, true)) { cancel = true; break; }
    }
    struct pollfd fds[3] = {
      {.fd = channel, .events = POLLIN | (queued(&out) ? POLLOUT : 0)},
      {.fd = output_closed ? -1 : output[0], .events = out.end - out.begin < QUEUE_MAX - CONTROL_RESERVE - CHUNK - 5 ? POLLIN : 0},
      {.fd = input[1], .events = queued(&in) ? POLLOUT : 0}};
    if (poll(fds, 3, 10) < 0 && errno != EINTR) break;
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      if (receive_bytes(channel, &control) < 0) { channel_alive = false; break; }
      size_t size; int parsed;
      while ((parsed = packet(&control, &size)) == 1) {
        unsigned char *data = control.bytes + 4;
        if (data[0] == 'C' && size == 1) cancel = true;
        else if (data[0] == 'A' && !dispatched && size == strlen(config->token) + 1 && !memcmp(data + 1, config->token, size - 1)) {
          byte = 'A';
          if (write(gate[1], &byte, 1) != 1) cancel = true;
          close(gate[1]); gate[1] = -1; dispatched = true;
        } else if (data[0] == 'E' && size == 1 && dispatched) eof = true;
        else if (data[0] == 'I' && dispatched && !eof) {
          if (enqueue(&in, data + 1, size - 1, false, false)) cancel = true;
        } else cancel = true;
        consume(&control, size);
      }
      if (parsed < 0) cancel = true;
    }
    if (fds[2].revents & POLLOUT) if (flush_queue(input[1], &in)) cancel = true;
    if (fds[1].revents & (POLLIN | POLLHUP)) {
      int result = output_frame(output[0], &out, &output_bytes, config, &output_closed);
      if (result) { limited = result == -2; cancel = true; }
    }
  }
  if (gate[1] >= 0) close(gate[1]);
  if (input[1] >= 0) close(input[1]);
  const char *error = "none";
  int clean = cleanup(child, config->timeout, &child_status, &error);
  int64_t drain_deadline = now_ms() + config->timeout;
  while (!output_closed && channel_alive && now_ms() < drain_deadline) {
    if (flush_queue(channel, &out)) { channel_alive = false; break; }
    if (out.end - out.begin < QUEUE_MAX - CONTROL_RESERVE - CHUNK - 5) {
      int result = output_frame(output[0], &out, &output_bytes, config, &output_closed);
      if (result) { limited = limited || result == -2; break; }
    }
    struct pollfd p = {.fd = output[0], .events = POLLIN}; (void)poll(&p, 1, 5);
  }
  if (!output_closed) { clean = -1; if (!strcmp(error, "none")) error = "output_drain_unconfirmed"; }
  close(output[0]);
  if (limited) (void)enqueue(&out, "L", 1, true, true);
  length = snprintf(message, sizeof(message), "K%s|%d|%s|closed|%s|reaped|%s", evidence, child_status,
    clean == 0 ? "confirmed" : "uncertain", dispatched ? "dispatched" : "never_started", error);
  if (channel_alive && length > 0 && (size_t)length < sizeof(message)) {
    (void)enqueue(&out, message, (size_t)length, true, true);
    flush_bounded(channel, &out, 200);
  }
  close(channel); _exit(clean == 0 ? 0 : 1);
}

static int broker(const struct config *config) {
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) || descriptor(sockets[0], true) || descriptor(sockets[1], true)) return 111;
  pid_t self = getpid(), guardian_pid = fork();
  if (guardian_pid < 0) return 111;
  if (!guardian_pid) { close(sockets[0]); guardian(config, sockets[1], self); }
  close(sockets[1]);
  if (descriptor(0, true) || descriptor(1, true)) { close(sockets[0]); return 111; }
  struct queue output = {0}, commands = {0}; struct reader input = {0}, events = {0};
  char ready[2048] = "", proof[4096] = ""; unsigned char final_frame[8192];
  bool cancelling = false, guardian_done = false, final = false, channel_closed = false;
  bool exit_ack = !config->exit_ack; int guardian_status = -1;
  int64_t deadline = INT64_MAX;
  for (;;) {
    if (flush_queue(1, &output)) break;
    if (!channel_closed && flush_queue(sockets[0], &commands)) cancelling = true;
    /* One read can complete/contain up to FRAME_MAX + 4 bytes. Keep enough
     * bounded output capacity for that entire batch before reading the stream.
     * Stdin remains polled independently, so control EOF still closes the
     * guardian lifeline when the output consumer is stalled. */
    bool receive_events = output.end - output.begin <= QUEUE_MAX - CONTROL_RESERVE - FRAME_MAX - 4;
    struct pollfd fds[3] = {
      {.fd = 0, .events = !cancelling || (final && !exit_ack) ? POLLIN : 0},
      {.fd = channel_closed || !receive_events ? -1 : sockets[0], .events = POLLIN | (queued(&commands) ? POLLOUT : 0)},
      {.fd = queued(&output) ? 1 : -1, .events = POLLOUT}};
    if (poll(fds, 3, 5) < 0 && errno != EINTR) break;
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      if (receive_bytes(0, &input) < 0) {
        if (final) break;
        cancelling = true;
      }
      size_t size; int parsed;
      while ((parsed = packet(&input, &size)) == 1) {
        unsigned char *data = input.bytes + 4;
        if (final) { if (size == 1 && data[0] == 'Q') exit_ack = true; }
        else if (enqueue(&commands, data, size, true, data[0] != 'I')) cancelling = true;
        if (size == 1 && data[0] == 'C') cancelling = true;
        consume(&input, size);
      }
      if (parsed < 0) cancelling = true;
    }
    if (cancelling && deadline == INT64_MAX) {
      /* EOF on this stream also cancels when a bounded queue is full. */
      flush_bounded(sockets[0], &commands, 10); shutdown(sockets[0], SHUT_WR);
      deadline = now_ms() + config->timeout + 500;
    }
    if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
      if (receive_bytes(sockets[0], &events) < 0) channel_closed = true;
      size_t size; int parsed;
      while ((parsed = packet(&events, &size)) == 1) {
        unsigned char *data = events.bytes + 4;
        if (data[0] == 'R' && size < sizeof(ready)) { memcpy(ready, data + 1, size - 1); ready[size - 1] = 0; }
        if (data[0] == 'K') {
          if (size < sizeof(proof)) { memcpy(proof, data + 1, size - 1); proof[size - 1] = 0; }
        } else if (enqueue(&output, data, size, true, data[0] != 'O')) cancelling = true;
        consume(&events, size);
      }
      if (parsed < 0) { channel_closed = true; cancelling = true; }
    }
    if (!guardian_done && waitpid(guardian_pid, &guardian_status, WNOHANG) == guardian_pid) guardian_done = true;
    /* A stream can contain a partial or queued K after the guardian exits.
     * Observe channel EOF before publishing its final proof. */
    if (guardian_done && channel_closed && !final) {
      int size;
      if (proof[0] && WIFEXITED(guardian_status) &&
          (WEXITSTATUS(guardian_status) == 0 || (WEXITSTATUS(guardian_status) == 1 && strstr(proof, "|uncertain|"))))
        size = snprintf((char *)final_frame, sizeof(final_frame), "F%s", proof);
      else size = snprintf((char *)final_frame, sizeof(final_frame), "F%s|-1|uncertain|unknown|unknown|reaped|guardian_proof_missing", ready);
      if (size < 0 || (size_t)size >= sizeof(final_frame) || enqueue(&output, final_frame, (size_t)size, true, true)) break;
      final = true; deadline = now_ms() + (config->exit_ack ? config->timeout : 100);
    }
    if (final && !queued(&output) && exit_ack) { close(sockets[0]); return 0; }
    if (now_ms() >= deadline) break;
  }
  close(sockets[0]);
  int64_t stopped = now_ms() + config->timeout + 500;
  while (!guardian_done && now_ms() < stopped) {
    if (waitpid(guardian_pid, &guardian_status, WNOHANG) == guardian_pid) guardian_done = true;
    else (void)poll(NULL, 0, 5);
  }
  return 1;
}
static long number(const char *text, long min, long max) {
  char *end; errno = 0; long n = strtol(text, &end, 10);
  return errno || !*text || *end || n < min || n > max ? -1 : n;
}
int backplane_macos_pipe(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc == 2 && !strcmp(argv[1], "--probe-pipe")) {
    struct identity self; int sockets[2], fds[2];
    if (exact_identity(getpid(), &self) || socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 1;
    close(sockets[0]); close(sockets[1]);
    if (make_pipe(fds)) return 1;
    close(fds[0]); close(fds[1]);
    return puts("BACKPLANE_PIPE 1") < 0 ? 1 : 0;
  }
  if (argc == 2 && !strcmp(argv[1], "--probe-exit-ack")) return puts("BACKPLANE_EXIT_ACK 1") < 0 ? 1 : 0;
  if (argc < 11 || (strcmp(argv[1], "--pipe") && strcmp(argv[1], "--pipe-ack"))) return 64;
  for (int i = 2; i <= 5; i++) if (!argv[i][0] || strlen(argv[i]) > 256 || strpbrk(argv[i], " |\n\r")) return 64;
  struct config config = {.token = argv[2], .owner = argv[3], .incarnation = argv[4], .session = argv[5],
    .rows = (int)number(argv[6], 1, 1000), .columns = (int)number(argv[7], 1, 1000),
    .timeout = (int)number(argv[8], 1, 4000), .limit = (size_t)number(argv[9], 0, LONG_MAX),
    .exit_ack = !strcmp(argv[1], "--pipe-ack"), .command = &argv[10]};
  if (config.rows < 0 || config.columns < 0 || config.timeout < 0 || config.limit == (size_t)-1 || argv[10][0] != '/') return 64;
  return broker(&config);
}
