#define _GNU_SOURCE
/* Linux-only optional packet4 PTY transport. No policy or sandbox is installed. */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define FRAME_MAX 65536U
#define QUEUE_MAX (262144U)
#define CONTROL_RESERVE 8192U
#define MEMBER_MAX 4096U
#define CHUNK 8192U

struct identity { pid_t pid, parent, group, session; unsigned long long start; char state; };
struct member { struct identity id; int fd; };
struct queue { unsigned char data[QUEUE_MAX]; size_t begin, end; };
struct reader { unsigned char data[FRAME_MAX + 4]; size_t used; };
struct config { const char *token, *owner, *incarnation, *session; int rows, columns, timeout; size_t output_limit; char **command; };

static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) _exit(111);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int nonblock(int fd) { int f = fcntl(fd, F_GETFL); return f < 0 ? -1 : fcntl(fd, F_SETFL, f | O_NONBLOCK); }
static int pidfd_open_(pid_t pid) { return (int)syscall(SYS_pidfd_open, pid, 0); }
static int pidfd_signal(int fd, int sig) { return (int)syscall(SYS_pidfd_send_signal, fd, sig, NULL, 0); }
static bool vanished(void) { return errno == ENOENT || errno == ESRCH; }

/* Read starttime as well as session on both sides of pidfd acquisition. */
static int identity(pid_t pid, struct identity *out) {
  char path[80], bytes[4096];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return vanished() ? 1 : -1;
  ssize_t n = read(fd, bytes, sizeof(bytes) - 1);
  int saved = errno;
  close(fd);
  errno = saved;
  if (n < 0) return vanished() ? 1 : -1;
  if (n == 0 || n >= (ssize_t)sizeof(bytes) - 1) return -1;
  bytes[n] = 0;
  char *rest = strrchr(bytes, ')');
  if (!rest || rest[1] != ' ') return -1;
  rest += 2;
  char *save = NULL, *field = strtok_r(rest, " ", &save);
  struct identity found = {.pid = pid};
  for (int number = 3; number <= 22; number++) {
    if (!field) return -1;
    char *end = NULL;
    if (number == 3) found.state = field[0];
    if (number == 4) found.parent = (pid_t)strtol(field, &end, 10);
    if (number == 5) found.group = (pid_t)strtol(field, &end, 10);
    if (number == 6) found.session = (pid_t)strtol(field, &end, 10);
    if (number == 22) found.start = strtoull(field, &end, 10);
    if (end && *end && *end != '\n') return -1;
    field = strtok_r(NULL, " ", &save);
  }
  *out = found;
  return 0;
}
static bool same(const struct identity *a, const struct identity *b) { return a->pid == b->pid && a->start == b->start && a->session == b->session; }
static bool exited(const struct identity *id) { return id->state == 'Z' || id->state == 'X' || id->state == 'x'; }
static bool numeric(const char *text) {
  if (*text < '1' || *text > '9') return false;
  for (const char *p = text; *p; p++) if (*p < '0' || *p > '9') return false;
  return true;
}
static int checked_pidfd(const struct identity *id) {
  int fd = pidfd_open_(id->pid);
  if (fd < 0) return vanished() ? -2 : -1;
  struct identity after;
  int result = identity(id->pid, &after);
  if (result != 0 || !same(id, &after)) { close(fd); return result == 1 ? -2 : -1; }
  return fd;
}

/* Complete census, bounded by MEMBER_MAX. Foreign unreadable entries are errors. */
static int census(pid_t sid, struct member *members, size_t *count) {
  DIR *dir = opendir("/proc");
  if (!dir) return -1;
  struct dirent *entry;
  int result = 0;
  errno = 0;
  while ((entry = readdir(dir))) {
    if (!numeric(entry->d_name)) continue;
    struct identity id;
    int status = identity((pid_t)strtol(entry->d_name, NULL, 10), &id);
    if (status == 1) { errno = 0; continue; }
    if (status < 0) { result = -1; break; }
    if (id.session != sid || exited(&id)) { errno = 0; continue; }
    bool known = false;
    for (size_t i = 0; i < *count; i++) if (same(&members[i].id, &id)) { known = true; break; }
    if (!known) {
      if (*count == MEMBER_MAX) { result = -1; break; }
      int fd = checked_pidfd(&id);
      if (fd == -2) { errno = 0; continue; }
      if (fd < 0) { result = -1; break; }
      members[*count] = (struct member){.id = id, .fd = fd};
      (*count)++;
    }
    errno = 0;
  }
  if (!entry && errno != 0) result = -1;
  closedir(dir);
  return result;
}
static int signal_members(struct member *members, size_t count, int sig) {
  for (size_t i = 0; i < count; i++) {
    if (pidfd_signal(members[i].fd, sig) < 0 && errno != ESRCH) return -1;
  }
  return 0;
}
static int live_member(const struct member *member) {
  struct pollfd p = {.fd = member->fd, .events = POLLIN};
  int ready = poll(&p, 1, 0);
  if (ready < 0) return -1;
  return ready == 0 ? 1 : 0;
}
static int stopped_threads(pid_t pid) {
  char path[80];
  snprintf(path, sizeof(path), "/proc/%d/task", pid);
  DIR *dir = opendir(path);
  if (!dir) return vanished() ? 1 : -1;
  int result = 1;
  struct dirent *entry;
  errno = 0;
  while ((entry = readdir(dir))) {
    if (!numeric(entry->d_name)) continue;
    struct identity id;
    int status = identity((pid_t)strtol(entry->d_name, NULL, 10), &id);
    if (status < 0) { result = -1; break; }
    if (status == 0 && !exited(&id) && id.state != 'T' && id.state != 't') result = 0;
    errno = 0;
  }
  if (!entry && errno != 0) result = -1;
  closedir(dir);
  return result;
}
static int cleanup_session(pid_t sid, int timeout, const char **error) {
  struct member *members = calloc(MEMBER_MAX, sizeof(*members));
  if (!members) { *error = "allocation"; return -1; }
  size_t count = 0;
  int64_t started = now_ms(), deadline = started + timeout;
  int result = -1;
  while (now_ms() < deadline) {
    size_t before = count;
    if (census(sid, members, &count) < 0) { *error = "proc_observation"; break; }
    if (now_ms() < started + 150) {
      if (signal_members(members + before, count - before, SIGTERM) < 0 ||
          signal_members(members + before, count - before, SIGCONT) < 0) { *error = "term_signal"; break; }
    } else {
      if (signal_members(members, count, SIGSTOP) < 0) { *error = "stop_signal"; break; }
      bool stopped = true;
      for (size_t i = 0; i < count; i++) {
        int live = live_member(&members[i]);
        if (live < 0) { *error = "pidfd_observation"; goto done; }
        if (live) {
          int status = stopped_threads(members[i].id.pid);
          if (status < 0) { *error = "thread_observation"; goto done; }
          if (!status) stopped = false;
        }
      }
      /* A second complete scan after all observed threads stop closes ordinary
       * fork admission. Newly discovered members require another stop round. */
      size_t stable = count;
      if (stopped) {
        if (census(sid, members, &count) < 0) { *error = "proc_observation"; break; }
        if (stable == count && signal_members(members, count, SIGKILL) < 0) { *error = "kill_signal"; break; }
      }
    }
    bool alive = false;
    for (size_t i = 0; i < count; i++) {
      int live = live_member(&members[i]);
      if (live < 0) { *error = "pidfd_observation"; goto done; }
      if (live) alive = true;
    }
    if (!alive) {
      size_t final = count;
      if (census(sid, members, &count) < 0) { *error = "final_census"; break; }
      if (count == final) { result = 0; *error = "none"; break; }
    }
    poll(NULL, 0, 5);
  }
  if (result != 0 && !strcmp(*error, "none")) *error = "cleanup_deadline";
done:
  for (size_t i = 0; i < count; i++) close(members[i].fd);
  free(members);
  return result;
}

static int enqueue(struct queue *q, const void *data, size_t size, bool packet, bool control) {
  size_t needed = size + (packet ? 4 : 0);
  size_t limit = control ? QUEUE_MAX : QUEUE_MAX - CONTROL_RESERVE;
  if (q->end - q->begin + needed > limit) return -1;
  if (q->end + needed > QUEUE_MAX) {
    memmove(q->data, q->data + q->begin, q->end - q->begin);
    q->end -= q->begin; q->begin = 0;
  }
  if (packet) { uint32_t n = htonl((uint32_t)size); memcpy(q->data + q->end, &n, 4); q->end += 4; }
  memcpy(q->data + q->end, data, size); q->end += size;
  return 0;
}
static int flush_queue(int fd, struct queue *q) {
  if (q->begin == q->end) return 0;
  ssize_t n = write(fd, q->data + q->begin, q->end - q->begin);
  if (n < 0) return errno == EAGAIN || errno == EINTR ? 0 : -1;
  q->begin += (size_t)n;
  if (q->begin == q->end) q->begin = q->end = 0;
  return 0;
}
static int send_message(int fd, const void *message, size_t length) {
  ssize_t n = send(fd, message, length, MSG_NOSIGNAL | MSG_DONTWAIT);
  return n == (ssize_t)length ? 0 : -1;
}
static void bounded_message(int fd, const void *message, size_t size, int timeout) {
  int64_t deadline = now_ms() + timeout;
  while (send_message(fd, message, size) < 0 && now_ms() < deadline) {
    struct pollfd p = {.fd = fd, .events = POLLOUT};
    if (poll(&p, 1, 5) < 0 || p.revents & (POLLERR | POLLHUP)) break;
  }
}
static int terminal_master(char *slave, size_t size, int rows, int columns) {
  int fd = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return -1;
  if (grantpt(fd) || unlockpt(fd) || ptsname_r(fd, slave, size)) { close(fd); return -1; }
  struct winsize dimensions = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns};
  if (ioctl(fd, TIOCSWINSZ, &dimensions)) { close(fd); return -1; }
  return fd;
}
static int child_terminal(const char *slave, int rows, int columns) {
  if (setsid() < 0) return -1;
  int fd = open(slave, O_RDWR | O_CLOEXEC);
  struct winsize dimensions = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)columns};
  if (fd < 0 || ioctl(fd, TIOCSCTTY, 0) || ioctl(fd, TIOCSWINSZ, &dimensions)) return -1;
  for (int i = 0; i < 3; i++) if (dup2(fd, i) < 0) return -1;
  if (fd > 2) close(fd);
  if (!isatty(0) || !isatty(1) || !isatty(2) || tcgetsid(0) != getpid()) return -1;
  return 0;
}
static void child_run(const struct config *config, const char *slave, int master, int socket_fd, int gate, int ready) {
  close(master); close(socket_fd);
  pid_t parent = getppid();
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent || child_terminal(slave, config->rows, config->columns)) _exit(125);
  char byte = 'R';
  if (write(ready, &byte, 1) != 1) _exit(125);
  close(ready);
  if (read(gate, &byte, 1) != 1 || byte != 'A') _exit(125);
  close(gate);
  /* Everything but the three slave descriptors is CLOEXEC or already closed. */
  signal(SIGPIPE, SIG_DFL);
  execv(config->command[0], config->command);
  _exit(127);
}
static void guardian(const struct config *config, int channel, pid_t broker) {
  int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
  if (null_fd < 0) _exit(111);
  for (int i = 0; i < 3; i++) if (dup2(null_fd, i) < 0) _exit(111);
  if (null_fd > 2) close(null_fd);
  char slave[PATH_MAX], evidence[2048];
  int master = terminal_master(slave, sizeof(slave), config->rows, config->columns);
  int gate[2], ready[2];
  if (master < 0 || pipe2(gate, O_CLOEXEC) || pipe2(ready, O_CLOEXEC)) _exit(111);
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0) _exit(111);
  pid_t child = fork();
  if (child < 0) _exit(111);
  if (!child) { close(gate[1]); close(ready[0]); child_run(config, slave, master, channel, gate[0], ready[1]); }
  close(gate[0]); close(ready[1]);
  struct pollfd setup = {.fd = ready[0], .events = POLLIN};
  char byte = 0;
  int setup_result = poll(&setup, 1, 1000);
  bool setup_ok = setup_result > 0 && read(ready[0], &byte, 1) == 1 && byte == 'R';
  close(ready[0]);
  struct identity b, g, c;
  bool identities_ok = identity(broker, &b) == 0 && identity(getpid(), &g) == 0 && identity(child, &c) == 0;
  bool identity_ok = identities_ok && c.parent == getpid() && c.session == child && c.group == child;
  if (!setup_ok || !identity_ok) {
    close(gate[1]);
    /* The pre-exec child either exited or is the exact fork child. pidfd only. */
    int fd = pidfd_open_(child);
    if (fd >= 0) { (void)pidfd_signal(fd, SIGKILL); close(fd); }
    int64_t deadline = now_ms() + 100;
    while (waitpid(child, NULL, WNOHANG) == 0 && now_ms() < deadline) poll(NULL, 0, 5);
    close(master); _exit(111);
  }
  snprintf(evidence, sizeof(evidence), "1 %s %d %llu %d %llu %d %llu %d %d %d %s %s %s", config->token, broker, b.start, getpid(), g.start, child, c.start, child, config->rows, config->columns, config->owner, config->incarnation, config->session);
  char message[FRAME_MAX];
  message[0] = 'R'; memcpy(message + 1, evidence, strlen(evidence));
  bounded_message(channel, message, strlen(evidence) + 1, 100);
  bool dispatched = false, cancel = false, child_seen = false, limited = false;
  int child_status = -1;
  size_t output_bytes = 0;
  struct queue input = {0};
  while (!cancel) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) { cancel = true; break; }
    if (info.si_pid == child) {
      child_seen = true;
      child_status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
      int length = snprintf(message, sizeof(message), "X%d", child_status);
      bounded_message(channel, message, (size_t)length, 10);
      break;
    }
    struct pollfd fds[2] = {{.fd = channel, .events = POLLIN}, {.fd = master, .events = POLLIN | (input.end > input.begin ? POLLOUT : 0)}};
    int polled = poll(fds, 2, 10);
    if (polled < 0 && errno != EINTR) { cancel = true; break; }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = recv(channel, message, sizeof(message), MSG_DONTWAIT);
      if (n <= 0) { cancel = true; break; }
      if (message[0] == 'C') { cancel = true; break; }
      if (message[0] == 'A' && !dispatched && (size_t)n == strlen(config->token) + 1 && !memcmp(message + 1, config->token, (size_t)n - 1)) {
        byte = 'A';
        if (write(gate[1], &byte, 1) != 1) { cancel = true; break; }
        close(gate[1]); gate[1] = -1; dispatched = true;
      } else if (message[0] == 'I' && dispatched) {
        if (enqueue(&input, message + 1, (size_t)n - 1, false, false)) { limited = true; cancel = true; break; }
      } else { cancel = true; break; }
    }
    if ((fds[1].revents & POLLOUT) && flush_queue(master, &input)) { cancel = true; break; }
    if (fds[1].revents & POLLIN) {
      ssize_t n = read(master, message + 1, CHUNK);
      if (n > 0) {
        size_t allowed = config->output_limit > output_bytes ? config->output_limit - output_bytes : 0;
        if ((size_t)n > allowed) { n = (ssize_t)allowed; limited = true; }
        message[0] = 'O';
        if (n && send_message(channel, message, (size_t)n + 1)) limited = true;
        output_bytes += (size_t)n;
        if (limited) { cancel = true; break; }
      }
    }
  }
  if (gate[1] >= 0) close(gate[1]);
  if (limited) bounded_message(channel, "L", 1, 10);
  const char *error = "none";
  int clean = cleanup_session(child, config->timeout, &error);
  /* Preserve final terminal bytes after normal exit, within the same byte cap. */
  for (int i = 0; i < 32; i++) {
    ssize_t n = read(master, message + 1, CHUNK);
    if (n <= 0) break;
    size_t allowed = config->output_limit > output_bytes ? config->output_limit - output_bytes : 0;
    if ((size_t)n > allowed) { n = (ssize_t)allowed; limited = true; }
    message[0] = 'O';
    if (n && send_message(channel, message, (size_t)n + 1)) limited = true;
    output_bytes += (size_t)n;
  }
  if (limited) bounded_message(channel, "L", 1, 10);
  if (!child_seen) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == child) {
      child_status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
      child_seen = true;
    }
  }
  /* No unbounded wait on a D-state leader: only reap observed exited children. */
  if (child_seen) {
    if (waitpid(child, NULL, WNOHANG) != child) { clean = -1; if (!strcmp(error, "none")) error = "leader_reap_unobserved"; }
  } else { clean = -1; if (!strcmp(error, "none")) error = "leader_exit_unobserved"; }
  while (waitpid(-1, NULL, WNOHANG) > 0) {}
  if (close(master) != 0) { clean = -1; if (!strcmp(error, "none")) error = "master_close"; }
  int length = snprintf(message, sizeof(message), "K%s|%d|%s|closed|%s|reaped|%s", evidence, child_status, clean == 0 ? "confirmed" : "uncertain", dispatched ? "dispatched" : "never_started", error);
  bounded_message(channel, message, (size_t)length, 50);
  close(channel);
  _exit(clean == 0 ? 0 : 1);
}

/* Broker sole Port endpoint. Both pipes and lifeline are nonblocking. */
static int broker(const struct config *config) {
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sockets)) return 111;
  pid_t guardian_pid = fork();
  if (guardian_pid < 0) return 111;
  if (!guardian_pid) { close(sockets[0]); guardian(config, sockets[1], getppid()); }
  close(sockets[1]);
  nonblock(STDIN_FILENO); nonblock(STDOUT_FILENO);
  struct queue output = {0};
  struct reader input = {0};
  unsigned char message[FRAME_MAX];
  char ready[2048] = "", proof[4096] = "";
  bool cancelling = false, guardian_done = false, final = false;
  int guardian_status = -1;
  int64_t stop_deadline = INT64_MAX;
  for (;;) {
    struct pollfd fds[3] = {{.fd = STDIN_FILENO, .events = cancelling ? 0 : POLLIN}, {.fd = STDOUT_FILENO, .events = output.end > output.begin ? POLLOUT : 0}, {.fd = sockets[0], .events = POLLIN}};
    if (poll(fds, 3, 5) < 0 && errno != EINTR) break;
    if (fds[1].revents & POLLOUT) if (flush_queue(STDOUT_FILENO, &output)) break;
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(STDIN_FILENO, input.data + input.used, sizeof(input.data) - input.used);
      if (n <= 0 && errno != EAGAIN && errno != EINTR) cancelling = true;
      if (n == 0) cancelling = true;
      if (n > 0) input.used += (size_t)n;
      while (input.used >= 4) {
        uint32_t length;
        memcpy(&length, input.data, 4); length = ntohl(length);
        if (!length || length > FRAME_MAX) { cancelling = true; break; }
        if (input.used < length + 4U) break;
        if (input.data[4] == 'C') cancelling = true;
        if (send_message(sockets[0], input.data + 4, length)) cancelling = true;
        memmove(input.data, input.data + length + 4, input.used - length - 4);
        input.used -= length + 4;
      }
    }
    if (cancelling && stop_deadline == INT64_MAX) {
      (void)send_message(sockets[0], "C", 1);
      /* SHUT_WR is reliable cancellation even when the bounded socket is full. */
      shutdown(sockets[0], SHUT_WR);
      stop_deadline = now_ms() + config->timeout + 200;
    }
    if (fds[2].revents & (POLLIN | POLLHUP | POLLERR)) {
      for (int i = 0; i < 64; i++) {
        ssize_t n = recv(sockets[0], message, sizeof(message), MSG_DONTWAIT);
        if (n <= 0) break;
        if (message[0] == 'R' && (size_t)n < sizeof(ready)) { memcpy(ready, message + 1, (size_t)n - 1); ready[n - 1] = 0; }
        if (message[0] == 'K') {
          if ((size_t)n < sizeof(proof)) { memcpy(proof, message + 1, (size_t)n - 1); proof[n - 1] = 0; }
        } else if (enqueue(&output, message, (size_t)n, true, message[0] != 'O')) {
          if (!cancelling) (void)enqueue(&output, "L", 1, true, true);
          cancelling = true;
        }
      }
    }
    if (!guardian_done) {
      pid_t waited = waitpid(guardian_pid, &guardian_status, WNOHANG);
      if (waited == guardian_pid) guardian_done = true;
    }
    if (guardian_done && !final) {
      /* Drain the result queued immediately before G exited. */
      ssize_t n;
      while ((n = recv(sockets[0], message, sizeof(message), MSG_DONTWAIT)) > 0) {
        if (message[0] == 'K' && (size_t)n < sizeof(proof)) { memcpy(proof, message + 1, (size_t)n - 1); proof[n - 1] = 0; }
        else if (message[0] != 'K') (void)enqueue(&output, message, (size_t)n, true, message[0] != 'O');
      }
      if (proof[0] && WIFEXITED(guardian_status) &&
          (WEXITSTATUS(guardian_status) == 0 || (WEXITSTATUS(guardian_status) == 1 && strstr(proof, "|uncertain|")))) {
        n = snprintf((char *)message, sizeof(message), "F%s", proof);
      } else {
        n = snprintf((char *)message, sizeof(message), "F%s|-1|uncertain|unknown|unknown|reaped|guardian_proof_missing", ready);
      }
      (void)enqueue(&output, message, (size_t)n, true, true);
      final = true;
      stop_deadline = now_ms() + 100;
    }
    if (final && output.end == output.begin) { close(sockets[0]); return 0; }
    if (now_ms() >= stop_deadline) break;
  }
  close(sockets[0]);
  /* Closing the lifeline asks G to clean; bounded wait never fabricates proof. */
  int64_t deadline = now_ms() + config->timeout + 100;
  while (!guardian_done && now_ms() < deadline) {
    if (waitpid(guardian_pid, &guardian_status, WNOHANG) == guardian_pid) guardian_done = true;
    else poll(NULL, 0, 5);
  }
  return 1;
}
static int probe(void) {
  struct identity self;
  if (identity(getpid(), &self)) return 1;
  struct member *members = calloc(MEMBER_MAX, sizeof(*members));
  if (!members) return 1;
  size_t count = 0;
  int observation = census(-1, members, &count);
  free(members);
  if (observation < 0) return 1;
  int fd = pidfd_open_(getpid());
  if (fd < 0 || pidfd_signal(fd, 0)) { if (fd >= 0) close(fd); return 1; }
  close(fd);
  char slave[PATH_MAX];
  int master = terminal_master(slave, sizeof(slave), 24, 80);
  if (master < 0) return 1;
  pid_t child = fork();
  if (child < 0) { close(master); return 1; }
  if (!child) { close(master); _exit(child_terminal(slave, 24, 80) == 0 ? 0 : 1); }
  int status;
  if (waitpid(child, &status, 0) != child) { close(master); return 1; }
  close(master);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
  return write(STDOUT_FILENO, "BACKPLANE_PTY 1\n", 16) == 16 ? 0 : 1;
}
static long number(const char *text, long minimum, long maximum) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  return errno || *end || value < minimum || value > maximum ? -1 : value;
}
int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc == 2 && !strcmp(argv[1], "--probe")) return probe();
  if (argc < 11 || strcmp(argv[1], "--run")) return 64;
  for (int i = 2; i <= 5; i++) if (!argv[i][0] || strlen(argv[i]) > 256 || strpbrk(argv[i], " |\n\r")) return 64;
  struct config config = {.token = argv[2], .owner = argv[3], .incarnation = argv[4], .session = argv[5],
    .rows = (int)number(argv[6], 1, 1000), .columns = (int)number(argv[7], 1, 1000),
    .timeout = (int)number(argv[8], 1, 4000), .output_limit = (size_t)number(argv[9], 1, LONG_MAX), .command = &argv[10]};
  if (config.rows < 0 || config.columns < 0 || config.timeout < 0 || config.output_limit == (size_t)-1 || argv[10][0] != '/') return 64;
  return broker(&config);
}
