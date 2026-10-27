#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Packet lengths include the type octet. All integers are network byte order. */
enum { HELLO=1, ACK=2, STARTED=3, DATA_IN=4, DATA_OUT=5, CLOSE=6,
       RECEIPT=7, ERROR_PACKET=8, TARGET_EXIT=9 };
#define MAX_DATA 65536u
#define QUEUE_LIMIT (1024u * 1024u)
#define MAX_PACKET (MAX_DATA + 1u)
struct queue { unsigned char bytes[QUEUE_LIMIT]; size_t used; };
static struct queue output, input;
static unsigned char inbox[MAX_PACKET + 4u];
static size_t inbox_used, drain_remaining;
static unsigned char token[16], close_token[16];
static pid_t child = -1;
static int child_in=-1, child_out=-1, exec_fd=-1;
static int reaped, target_status, term_sent, kill_sent, closing, receipt_queued;
static int startup_ack, started, protocol_error, stdin_open=1, pipes_closed, pipe_close_failed;
static int64_t close_at, term_at, kill_at, finish_at;
static volatile sig_atomic_t interrupted;

static int64_t now_ms(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) _exit(70);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static uint32_t get32(const unsigned char *p) {
  return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
static void put32(unsigned char *p, uint32_t n) {
  p[0]=(unsigned char)(n>>24); p[1]=(unsigned char)(n>>16);
  p[2]=(unsigned char)(n>>8); p[3]=(unsigned char)n;
}
static void close_owned(int fd) {
  if (close(fd) != 0) pipe_close_failed=1; /* EINTR is ambiguous across POSIX hosts. */
}
static void close_fd(int *fd) {
  if (*fd >= 0) { close_owned(*fd); *fd=-1; }
}
static int nonblock(int fd) {
  int flags=fcntl(fd,F_GETFL,0);
  return flags < 0 ? -1 : fcntl(fd,F_SETFL,flags|O_NONBLOCK);
}
static void on_signal(int sig) { (void)sig; interrupted=1; }
static int packet(unsigned char type, const void *data, size_t len) {
  if (len > MAX_DATA || output.used + len + 5 > QUEUE_LIMIT) return -1;
  put32(output.bytes+output.used,(uint32_t)len+1);
  output.bytes[output.used+4]=type;
  if (len) memcpy(output.bytes+output.used+5,data,len);
  output.used += len+5;
  return 0;
}
static void flush_queue(int fd, struct queue *q) {
  if (!q->used || fd < 0) return;
  ssize_t n=write(fd,q->bytes,q->used);
  if (n > 0) {
    q->used -= (size_t)n;
    memmove(q->bytes,q->bytes+n,q->used);
  } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
    if (fd == STDOUT_FILENO) { interrupted=1; output.used=0; }
    else { close_fd(&child_in); input.used=0; }
  }
}
static void begin_close(uint32_t budget, const unsigned char *nonce) {
  if (closing) return;
  closing=1;
  if (nonce) memcpy(close_token,nonce,16);
  close_at=now_ms();
  finish_at=close_at+(int64_t)budget;
  /* Reserve time for reaping, receipt delivery and helper exit. */
  int64_t grace=budget/4;
  if (grace > 250) grace=250;
  term_at=close_at+grace;
  kill_at=close_at+((int64_t)budget/2);
  close_fd(&child_in);
  input.used=0;
}
static void error_packet(uint32_t code) {
  unsigned char b[4]; put32(b,code);
  (void)packet(ERROR_PACKET,b,sizeof b);
  protocol_error=1;
  begin_close(500,NULL);
}
static void fork_target(char **argv) {
  int to_child[2], from_child[2], exec_error[2];
  if (pipe(to_child) || pipe(from_child) || pipe(exec_error)) { error_packet(1); return; }
  if (fcntl(exec_error[1],F_SETFD,FD_CLOEXEC) < 0) { error_packet(2); return; }
  child=fork();
  if (child == 0) {
    close(to_child[1]); close(from_child[0]); close(exec_error[0]);
    if (dup2(to_child[0],STDIN_FILENO) < 0 || dup2(from_child[1],STDOUT_FILENO) < 0) _exit(126);
    close(to_child[0]); close(from_child[1]);
    signal(SIGPIPE,SIG_DFL); signal(SIGTERM,SIG_DFL); signal(SIGINT,SIG_DFL);
    execv(argv[0],argv);
    int failure=errno;
    ssize_t written;
    do { written=write(exec_error[1],&failure,sizeof failure); } while (written < 0 && errno == EINTR);
    if (written != (ssize_t)sizeof failure) _exit(126);
    _exit(127);
  }
  close_owned(to_child[0]); close_owned(from_child[1]); close_owned(exec_error[1]);
  if (child < 0) { close(to_child[1]); close(from_child[0]); close(exec_error[0]); error_packet(3); return; }
  child_in=to_child[1]; child_out=from_child[0]; exec_fd=exec_error[0];
  if (nonblock(child_in) || nonblock(child_out) || nonblock(exec_fd)) error_packet(4);
}
static void reap_child(void) {
  if (child <= 0 || reaped) return;
  int status;
  pid_t result=waitpid(child,&status,WNOHANG);
  if (result == child) {
    target_status=status;
    reaped=1;
    /* Freeze the finite unread bytes at reap, not a descendant's future writes.
       Drain across queue flushes; never wait for a descendant-held EOF. */
    if (child_out >= 0) {
      int available=0;
      if (ioctl(child_out,FIONREAD,&available) != 0 || available < 0) {
        close_fd(&child_out); error_packet(15);
      } else {
        drain_remaining=(size_t)available;
        if (!drain_remaining) close_fd(&child_out);
      }
    }
    close_fd(&child_in);
    input.used=0;
    unsigned char b[9]; put32(b,(uint32_t)child);
    b[4]=(unsigned char)(WIFEXITED(status)?0:1);
    put32(b+5,(uint32_t)(WIFEXITED(status)?WEXITSTATUS(status):WTERMSIG(status)));
    (void)packet(TARGET_EXIT,b,sizeof b);
  } else if (result < 0 && errno != EINTR) {
    /* Never signal after losing the exact unreaped-child relationship. */
    child=-1; error_packet(5);
  }
}
static void signal_child(int sig) {
  reap_child();
  if (child > 0 && !reaped) {
    /* child remains our unreaped direct child; its PID cannot be reused. */
    if (kill(child,sig) == 0) {
      if (sig == SIGTERM) term_sent=1;
      if (sig == SIGKILL) kill_sent=1;
    }
  }
}
static void read_target(void) {
  if (child_out < 0 || output.used + 16389 > QUEUE_LIMIT) return;
  unsigned char data[16384];
  size_t limit=sizeof data;
  if (reaped && drain_remaining < limit) limit=drain_remaining;
  if (!limit) { close_fd(&child_out); return; }
  ssize_t n=read(child_out,data,limit);
  if (n > 0) {
    (void)packet(DATA_OUT,data,(size_t)n);
    if (reaped) {
      drain_remaining-=(size_t)n;
      if (!drain_remaining) close_fd(&child_out);
    }
  }
  else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) close_fd(&child_out);
}
static void make_receipt(void) {
  if (receipt_queued || !reaped) return;
  close_fd(&child_in); close_fd(&child_out); close_fd(&exec_fd);
  pipes_closed=(!pipe_close_failed && child_in < 0 && child_out < 0 && exec_fd < 0);
  unsigned char b[45];
  memcpy(b,token,16); memcpy(b+16,close_token,16); put32(b+32,(uint32_t)child);
  b[36]=(unsigned char)(WIFEXITED(target_status)?0:1);
  put32(b+37,(uint32_t)(WIFEXITED(target_status)?WEXITSTATUS(target_status):WTERMSIG(target_status)));
  b[41]=(unsigned char)reaped; b[42]=(unsigned char)pipes_closed;
  b[43]=(unsigned char)term_sent; b[44]=(unsigned char)kill_sent;
  if (packet(RECEIPT,b,sizeof b) == 0) receipt_queued=1;
}
static void handle_packet(const unsigned char *p,size_t n,char **target) {
  if (!n) { error_packet(6); return; }
  switch (p[0]) {
    case ACK:
      if (n != 17 || startup_ack || memcmp(p+1,token,16)) { error_packet(7); break; }
      startup_ack=1;
      if (!closing) fork_target(target);
      break;
    case DATA_IN:
      if (!started || closing || child_in < 0 || n-1 > MAX_DATA) { if (!closing) error_packet(8); break; }
      if (input.used+n-1 > QUEUE_LIMIT) { error_packet(9); break; }
      memcpy(input.bytes+input.used,p+1,n-1); input.used+=n-1;
      break;
    case CLOSE:
      if (n != 37 || memcmp(p+1,token,16) || get32(p+33) == 0) { error_packet(10); break; }
      begin_close(get32(p+33),p+17);
      break;
    default: error_packet(11); break;
  }
}
static void read_control(char **target) {
  ssize_t n=read(STDIN_FILENO,inbox+inbox_used,sizeof inbox-inbox_used);
  if (n > 0) inbox_used+=(size_t)n;
  else if (n == 0) { stdin_open=0; begin_close(1000,NULL); }
  else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { stdin_open=0; begin_close(1000,NULL); }
  while (inbox_used >= 4) {
    uint32_t length=get32(inbox);
    if (length == 0 || length > MAX_PACKET) { inbox_used=0; error_packet(12); break; }
    if (inbox_used < length+4u) break;
    handle_packet(inbox+4,length,target);
    inbox_used-=length+4u;
    memmove(inbox,inbox+length+4u,inbox_used);
  }
}
static int parse_token(const char *s) {
  if (strlen(s) != 32) return -1;
  for (int i=0;i<16;i++) {
    unsigned int n;
    char piece[3]={s[i*2],s[i*2+1],0};
    if (sscanf(piece,"%2x",&n) != 1) return -1;
    token[i]=(unsigned char)n;
  }
  return 0;
}
int main(int argc,char **argv) {
  if (argc == 2 && strcmp(argv[1],"--probe") == 0) {
    puts("backplane-mcp-stdio-guardian 1"); return 0;
  }
  if (argc < 5 || strcmp(argv[1],"--token") || strcmp(argv[3],"--") || parse_token(argv[2])) return 64;
  signal(SIGPIPE,SIG_IGN); signal(SIGTERM,on_signal); signal(SIGINT,on_signal);
  if (nonblock(STDIN_FILENO) || nonblock(STDOUT_FILENO)) return 70;
  unsigned char hello[18]={0,1}; memcpy(hello+2,token,16);
  (void)packet(HELLO,hello,sizeof hello);
  int64_t startup_deadline=now_ms()+5000;
  for (;;) {
    int64_t now=now_ms();
    if (interrupted) begin_close(1000,NULL);
    if (!startup_ack && now >= startup_deadline) begin_close(500,NULL);
    reap_child();
    if (closing) {
      if (now >= term_at && !term_sent) signal_child(SIGTERM);
      if (now >= kill_at && !kill_sent) signal_child(SIGKILL);
      reap_child();
      if (reaped) {
        read_target();
        if (child_out < 0) make_receipt();
      }
      if (receipt_queued && output.used == 0) return (protocol_error || pipe_close_failed)?65:0;
      if (now >= finish_at) {
        signal_child(SIGKILL);
        reap_child();
        close_fd(&child_in); close_fd(&child_out); close_fd(&exec_fd);
        return 75; /* No complete receipt+exit success is invented at deadline. */
      }
      if (child <= 0 && output.used == 0) return (protocol_error || pipe_close_failed)?65:0;
    } else if (reaped) {
      read_target();
      if (started) close_fd(&exec_fd);
    }
    struct pollfd fds[5]={
      {stdin_open?STDIN_FILENO:-1,POLLIN,0},
      {STDOUT_FILENO,output.used?POLLOUT:0,0},
      {child_in,input.used?POLLOUT:0,0},
      {child_out,(output.used+16389 <= QUEUE_LIMIT)?POLLIN:0,0},
      {exec_fd,POLLIN,0}
    };
    int timeout=10;
    if (closing && finish_at-now < timeout) timeout=(int)(finish_at-now);
    if (timeout < 0) timeout=0;
    int ready=poll(fds,5,timeout);
    if (ready < 0 && errno != EINTR) { error_packet(13); continue; }
    if (fds[0].revents & (POLLIN|POLLHUP|POLLERR)) read_control(argv+4);
    if (fds[1].revents & POLLOUT) flush_queue(STDOUT_FILENO,&output);
    if (fds[2].revents & (POLLOUT|POLLHUP|POLLERR)) flush_queue(child_in,&input);
    if (fds[3].revents & (POLLIN|POLLHUP|POLLERR)) read_target();
    if (exec_fd >= 0 && (fds[4].revents & (POLLIN|POLLHUP|POLLERR))) {
      int failure=0;
      ssize_t n=read(exec_fd,&failure,sizeof failure);
      if (n == 0) {
        close_fd(&exec_fd); started=1;
        unsigned char b[20]; memcpy(b,token,16); put32(b+16,(uint32_t)child);
        (void)packet(STARTED,b,sizeof b);
      } else if (n > 0) { close_fd(&exec_fd); error_packet(14); }
    }
  }
}
