#define _GNU_SOURCE
/* Unit seams use real identities/pidfds; only directory read errors are injected. */
#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
static bool fail_directory;
static struct dirent *test_readdir(DIR *dir);
#define readdir test_readdir
#define main pty_helper_main
#include "../../c_src/local_command_pty.c"
#undef main
#undef readdir
#include <assert.h>

static struct dirent *test_readdir(DIR *dir) {
  if (fail_directory) { errno = EACCES; return NULL; }
  return readdir(dir);
}
int main(void) {
  struct identity self;
  assert(identity(getpid(), &self) == 0);
  int fd = checked_pidfd(&self);
  assert(fd >= 0);
  close(fd);
  self.start++;
  assert(checked_pidfd(&self) == -1);
  self.start--;
  self.session++;
  assert(checked_pidfd(&self) == -1);
  struct member *members = calloc(MEMBER_MAX, sizeof(*members));
  assert(members != NULL);
  size_t count = 0;
  fail_directory = true;
  assert(census(-1, members, &count) == -1);
  const char *error = "none";
  assert(cleanup_session(-1, 100, &error) == -1);
  assert(strcmp(error, "proc_observation") == 0);
  fail_directory = false;
  free(members);

  int ready[2];
  assert(pipe(ready) == 0);
  pid_t child = fork();
  assert(child >= 0);
  if (!child) {
    close(ready[0]);
    assert(setsid() >= 0);
    signal(SIGTERM, SIG_IGN);
    assert(write(ready[1], "R", 1) == 1);
    for (;;) pause();
  }
  close(ready[1]);
  char byte;
  assert(read(ready[0], &byte, 1) == 1);
  close(ready[0]);
  error = "none";
  int64_t started = now_ms();
  assert(cleanup_session(child, 1, &error) == -1);
  assert(now_ms() - started < 100);
  assert(strcmp(error, "cleanup_deadline") == 0);
  fd = pidfd_open_(child);
  assert(fd >= 0);
  assert(pidfd_signal(fd, SIGKILL) == 0);
  close(fd);
  assert(waitpid(child, NULL, 0) == child);
  puts("PTY identity/observation/deadline checks: PASS");
  return 0;
}
