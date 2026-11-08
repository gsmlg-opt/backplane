#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

/* No shell interpretation: arguments pass unchanged into the blocked launcher. */
static int launch(char **argv) {
  pid_t child = fork();
  if (child < 0) return 125;
  if (child == 0) {
    if (setsid() < 0) _exit(125);
    execv(argv[0], argv);
    _exit(127);
  }
  int status;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 125;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 125;
}

static int positive_pid(const char *text, pid_t *pid) {
  char *end;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno || !*text || *end || value <= 0 || value > INT_MAX) return -1;
  *pid = (pid_t)value;
  return 0;
}

static int exists(pid_t target) {
  if (kill(target, 0) == 0 || errno == EPERM) {
    puts("present");
    return 0;
  }
  if (errno == ESRCH) {
    puts("absent");
    return 0;
  }
  return 1;
}

static int identity(pid_t pid) {
#ifdef __APPLE__
  struct proc_bsdinfo info;
  int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  if (size != (int)sizeof(info)) return 1;
  pid_t session = getsid(pid);
  if (session < 0 || info.pbi_pid != (unsigned int)pid) return 1;
  printf("%u %u %ld %llu:%llu\n", info.pbi_ppid, info.pbi_pgid, (long)session,
         (unsigned long long)info.pbi_start_tvsec, (unsigned long long)info.pbi_start_tvusec);
  return 0;
#else
  (void)pid;
  return 1;
#endif
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
    puts("BACKPLANE_SESSION 1");
    return 0;
  }
  if (argc >= 3 && strcmp(argv[1], "--run") == 0) return launch(&argv[2]);
  pid_t pid;
  if (argc != 3 || positive_pid(argv[2], &pid) != 0) return 2;
  if (strcmp(argv[1], "--term") == 0) return kill(-pid, SIGTERM) == 0 ? 0 : 1;
  if (strcmp(argv[1], "--kill") == 0) return kill(-pid, SIGKILL) == 0 ? 0 : 1;
  if (strcmp(argv[1], "--identity") == 0) return identity(pid);
  if (strcmp(argv[1], "--alive") == 0) return exists(pid);
  if (strcmp(argv[1], "--group-exists") == 0) return exists(-pid);
  return 2;
}
