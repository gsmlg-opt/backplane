/* Backplane audio launcher: packet4 control, isolated media worker, owning guardian.
 * No shell, inherited environment, executable paths from media, or media stdout.
 * The guardian is intentionally outside the worker sandbox so it can always reap.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <elf.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/sched.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#else
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <sys/mman.h>
#endif

#define MAX_LIBS 512
#define MAX_DIAG 4096
#define MAX_DEP_OUTPUT (256 * 1024)
static char *safe_env[] = {"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "HOME=/nonexistent", "TMPDIR=.", NULL};
struct options { const char *mode; char workdir[PATH_MAX]; char executable[PATH_MAX];
  char self[PATH_MAX]; char **args; uint64_t deadline; rlim_t max_file; size_t stderr_max; };
struct paths { char *p[MAX_LIBS]; size_t count; };
static struct paths libs;

static uint64_t now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void be32(unsigned char *p, uint32_t n) { p[0]=n>>24; p[1]=n>>16; p[2]=n>>8; p[3]=n; }
static bool write_all(int fd, const void *buf, size_t size) {
  const unsigned char *p=buf;
  while(size) { ssize_t n=write(fd,p,size); if(n<0 && errno==EINTR) continue; if(n<=0) return false; p+=n; size-=(size_t)n; }
  return true;
}
static void frame(const void *data, size_t size) { unsigned char h[4]; be32(h,(uint32_t)size); if(write_all(1,h,4)) (void)write_all(1,data,size); }
static void error_frame(const char *code) { char buf[64]; int n=snprintf(buf,sizeof(buf),"E%s",code); if(n>0 && (size_t)n<sizeof(buf)) frame(buf,(size_t)n); }
static void exit_frame(int status, bool clean) { unsigned char b[7]={'X',0,0,0,0,0,0};
  if(status<0) be32(b+1,UINT32_MAX);
  else if(WIFEXITED(status)) be32(b+1,(uint32_t)WEXITSTATUS(status));
  if(status>=0&&WIFSIGNALED(status)) b[5]=(unsigned char)WTERMSIG(status);
  b[6]=clean?1:0; frame(b,7); }
static void close_above(int low) {
#ifdef __linux__
#ifdef __NR_close_range
  if(syscall(__NR_close_range,(unsigned)low,~0U,0)==0) return;
#endif
#endif
  long limit=sysconf(_SC_OPEN_MAX); if(limit<0) limit=65536;
  for(int i=low;i<limit;i++) close(i);
}
static bool add_path(const char *path) {
  char resolved[PATH_MAX]; struct stat st;
  if(!realpath(path,resolved)||stat(resolved,&st)||!S_ISREG(st.st_mode)) return false;
  for(size_t i=0;i<libs.count;i++) if(!strcmp(libs.p[i],resolved)) return true;
  if(libs.count==MAX_LIBS) return false;
  libs.p[libs.count]=strdup(resolved); if(!libs.p[libs.count]) return false; libs.count++; return true;
}
static bool limit_resource(int which, rlim_t n) { struct rlimit r={n,n}; return setrlimit(which,&r)==0; }
static bool limits(const struct options *o) {
  bool ok=limit_resource(RLIMIT_CORE,0)&&limit_resource(RLIMIT_NOFILE,64)&&
    limit_resource(RLIMIT_FSIZE,o->max_file)&&limit_resource(RLIMIT_CPU,(rlim_t)(o->deadline/1000+2));
#ifdef __linux__
  ok=ok&&limit_resource(RLIMIT_AS,(rlim_t)2*1024*1024*1024);
#endif
  return ok;
}

static const char *worker_resource_failure(pid_t pid) {
#ifdef __linux__
  /* RLIMIT_NPROC counts all threads with the real UID, including BEAM. Count
   * this worker's thread group instead; seccomp forbids descendant processes.
   * The guardian remains outside confinement and retains the unreaped PID. */
  char path[64];snprintf(path,sizeof(path),"/proc/%ld/status",(long)pid);
  FILE *status=fopen(path,"r");if(!status)return "sandbox_unavailable";
  char line[256];unsigned long threads=0;bool found=false;
  while(fgets(line,sizeof(line),status)) {
    if(sscanf(line,"Threads: %lu",&threads)==1){found=true;break;}
  }
  fclose(status);
  if(!found)return "sandbox_unavailable";
  return threads>64?"resource_limit":NULL;
#else
  /* Darwin has no usable RLIMIT_AS, so RSS is also sampled. */
  struct proc_taskinfo taskinfo;
  if(proc_pidinfo(pid,PROC_PIDTASKINFO,0,&taskinfo,sizeof(taskinfo))==sizeof(taskinfo)&&
     (taskinfo.pti_resident_size>(uint64_t)2*1024*1024*1024||taskinfo.pti_threadnum>64))return "resource_limit";
  return NULL;
#endif
}

#ifdef __linux__
/* Ask the ELF interpreter for its resolved dependency list, without executing the
 * selected program. Both interpreter and every resolved library are exact rules.
 */
static bool dependencies(const char *executable) {
  int fd=open(executable,O_RDONLY|O_CLOEXEC); if(fd<0) return false;
  Elf64_Ehdr eh; bool ok=pread(fd,&eh,sizeof(eh),0)==sizeof(eh) &&
    !memcmp(eh.e_ident,ELFMAG,SELFMAG)&&eh.e_ident[EI_CLASS]==ELFCLASS64&&
    eh.e_ident[EI_DATA]==ELFDATA2LSB&&eh.e_phentsize==sizeof(Elf64_Phdr)&&eh.e_phnum<=256;
  char loader[PATH_MAX]={0};
  for(unsigned i=0;ok&&i<eh.e_phnum;i++) { Elf64_Phdr ph;
    if(pread(fd,&ph,sizeof(ph),(off_t)eh.e_phoff+(off_t)i*sizeof(ph))!=sizeof(ph)) {ok=false;break;}
    if(ph.p_type==PT_INTERP) { if(ph.p_filesz<2||ph.p_filesz>=sizeof(loader)||pread(fd,loader,ph.p_filesz,(off_t)ph.p_offset)!=(ssize_t)ph.p_filesz) ok=false; }
  }
  close(fd); if(!ok||!add_path(executable)) return false;
  if(!loader[0]) return true; /* statically linked trusted executable */
  if(!add_path(loader)) return false;
  int pipefd[2]; if(pipe(pipefd)) return false;
  pid_t child=fork(); if(child<0) {close(pipefd[0]);close(pipefd[1]);return false;}
  if(!child) { dup2(pipefd[1],1); int null=open("/dev/null",O_RDWR); dup2(null,0);dup2(null,2);close_above(3);
    char *args[]={loader,"--list",(char*)executable,NULL};execve(loader,args,safe_env);_exit(127); }
  close(pipefd[1]); fcntl(pipefd[0],F_SETFL,O_NONBLOCK);
  char *output=calloc(1,MAX_DEP_OUTPUT+1); size_t used=0; uint64_t end=now_ms()+3000; int status=0; bool eof=false;
  if(!output) ok=false;
  while(ok&&!eof&&now_ms()<end) { struct pollfd p={pipefd[0],POLLIN,0}; poll(&p,1,30);
    ssize_t n=read(pipefd[0],output+used,MAX_DEP_OUTPUT-used);
    if(n>0) {used+=(size_t)n;if(used==MAX_DEP_OUTPUT) ok=false;}
    else if(n==0) eof=true; else if(errno!=EAGAIN&&errno!=EINTR) ok=false;
  }
  if(!eof) {ok=false;kill(child,SIGKILL);} close(pipefd[0]); while(waitpid(child,&status,0)<0&&errno==EINTR) {}
  ok=ok&&WIFEXITED(status)&&WEXITSTATUS(status)==0;
  char *save=NULL;
  for(char *line=ok?strtok_r(output,"\n",&save):NULL;line;line=strtok_r(NULL,"\n",&save)) {
    char *path=strstr(line,"=> "); path=path?path+3:line; while(*path==' '||*path=='\t') path++;
    if(*path=='/') {char *endpath=strstr(path," ("); if(!endpath) {ok=false;break;} *endpath=0; if(!add_path(path)) {ok=false;break;}}
    else if(strstr(path,"not found")) {ok=false;break;}
  }
  free(output); return ok;
}
#ifndef LANDLOCK_ACCESS_FS_REFER
#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif
#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif
static bool landlock_rule(int ruleset,const char *path,uint64_t access) {
  int fd=open(path,O_PATH|O_CLOEXEC);if(fd<0) return false;
  struct landlock_path_beneath_attr a={.allowed_access=access,.parent_fd=fd};
  bool ok=syscall(__NR_landlock_add_rule,ruleset,LANDLOCK_RULE_PATH_BENEATH,&a,0)==0;close(fd);return ok;
}
static bool filesystem_sandbox(const struct options *o) {
  int abi=(int)syscall(__NR_landlock_create_ruleset,NULL,0,LANDLOCK_CREATE_RULESET_VERSION); if(abi<3) return false;
  uint64_t handled=(1ULL<<15)-1;
  struct landlock_ruleset_attr a={.handled_access_fs=handled};
  int rs=(int)syscall(__NR_landlock_create_ruleset,&a,sizeof(a),0);if(rs<0)return false;
  uint64_t work=LANDLOCK_ACCESS_FS_READ_FILE|LANDLOCK_ACCESS_FS_READ_DIR|LANDLOCK_ACCESS_FS_WRITE_FILE|
    LANDLOCK_ACCESS_FS_REMOVE_DIR|LANDLOCK_ACCESS_FS_REMOVE_FILE|LANDLOCK_ACCESS_FS_MAKE_DIR|
    LANDLOCK_ACCESS_FS_MAKE_REG|LANDLOCK_ACCESS_FS_MAKE_SYM|LANDLOCK_ACCESS_FS_REFER|LANDLOCK_ACCESS_FS_TRUNCATE;
  bool ok=landlock_rule(rs,o->workdir,work);
  for(size_t i=0;ok&&i<libs.count;i++) ok=landlock_rule(rs,libs.p[i],LANDLOCK_ACCESS_FS_READ_FILE|LANDLOCK_ACCESS_FS_EXECUTE);
  if(access("/etc/ld.so.cache",F_OK)==0) ok=ok&&landlock_rule(rs,"/etc/ld.so.cache",LANDLOCK_ACCESS_FS_READ_FILE);
  ok=ok&&prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)==0&&syscall(__NR_landlock_restrict_self,rs,0)==0;
  close(rs);return ok;
}
#define DENY_SYSCALL(n) BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,(n),0,1), BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM)
static bool syscall_sandbox(void) {
#if defined(__aarch64__)
#define NATIVE_ARCH AUDIT_ARCH_AARCH64
#elif defined(__x86_64__)
#define NATIVE_ARCH AUDIT_ARCH_X86_64
#else
#error Unsupported launcher architecture
#endif
  const uint32_t thread_flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_SYSVSEM|CLONE_SETTLS|CLONE_PARENT_SETTID|CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID;
  struct sock_filter code[]={
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,arch)),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,NATIVE_ARCH,1,0),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
    /* x32 uses the x86_64 audit arch but a different syscall namespace. */
    BPF_JUMP(BPF_JMP|BPF_JGE|BPF_K,0x40000000U,0,1),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_KILL_PROCESS),
#ifdef __NR_clone3
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,__NR_clone3,0,1),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|ENOSYS),
#endif
#ifdef __NR_fork
    DENY_SYSCALL(__NR_fork),
#endif
#ifdef __NR_vfork
    DENY_SYSCALL(__NR_vfork),
#endif
    DENY_SYSCALL(__NR_socket),DENY_SYSCALL(__NR_socketpair),DENY_SYSCALL(__NR_ptrace),
    DENY_SYSCALL(__NR_kill),DENY_SYSCALL(__NR_tkill),
    DENY_SYSCALL(__NR_setsid),DENY_SYSCALL(__NR_setpgid),DENY_SYSCALL(__NR_unshare),DENY_SYSCALL(__NR_setns),
    DENY_SYSCALL(__NR_mount),DENY_SYSCALL(__NR_umount2),DENY_SYSCALL(__NR_pivot_root),DENY_SYSCALL(__NR_chroot),
    DENY_SYSCALL(__NR_process_vm_readv),DENY_SYSCALL(__NR_process_vm_writev),DENY_SYSCALL(__NR_open_by_handle_at),
    DENY_SYSCALL(__NR_bpf),DENY_SYSCALL(__NR_perf_event_open),DENY_SYSCALL(__NR_userfaultfd),
    DENY_SYSCALL(__NR_keyctl),DENY_SYSCALL(__NR_add_key),DENY_SYSCALL(__NR_request_key),DENY_SYSCALL(__NR_execveat),
#ifdef __NR_io_uring_setup
    DENY_SYSCALL(__NR_io_uring_setup),DENY_SYSCALL(__NR_io_uring_enter),DENY_SYSCALL(__NR_io_uring_register),
#endif
    /* pthread cancellation/raise may signal only this worker's thread group. */
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,__NR_tgkill,0,4),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[0])),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,(uint32_t)getpid(),1,0),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
    /* Permit libc threads only: no process clones or namespace flags. */
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,__NR_clone,1,0),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[0])+4),
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,0,1,0),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[0])),
    BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K,CLONE_THREAD,1,0),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
    BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K,~thread_flags,0,1),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
    BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)
  };
  struct sock_fprog f={.len=(unsigned short)(sizeof(code)/sizeof(code[0])),.filter=code};
  return prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&f)==0;
}
#else
/* Read trusted Mach-O dependency commands directly; no otool/Developer Tools
 * runtime requirement. System libraries are supplied by the OS dyld cache.
 */
static bool system_library(const char *p) {return !strncmp(p,"/usr/lib/",9)||!strncmp(p,"/System/Library/",16);}
static bool dependencies(const char *executable) {
  if(!add_path(executable)) return false;
  for(size_t at=0;at<libs.count;at++) {
    int fd=open(libs.p[at],O_RDONLY);if(fd<0)return false;struct stat st;
    if(fstat(fd,&st)||st.st_size<32) {close(fd);return false;}
    unsigned char *map=mmap(NULL,(size_t)st.st_size,PROT_READ,MAP_PRIVATE,fd,0);close(fd);if(map==MAP_FAILED)return false;
    size_t offset=0;uint32_t magic;memcpy(&magic,map,4);
    if(magic==FAT_CIGAM) {
      struct fat_header *fat=(struct fat_header*)map;uint32_t count=__builtin_bswap32(fat->nfat_arch);bool found=false;
      if(count>32||sizeof(*fat)+(size_t)count*sizeof(struct fat_arch)>(size_t)st.st_size){munmap(map,(size_t)st.st_size);return false;}
      struct fat_arch *arches=(struct fat_arch*)(map+sizeof(*fat));
      for(uint32_t i=0;i<count;i++) {
#ifdef __aarch64__
        const uint32_t cpu=CPU_TYPE_ARM64;
#else
        const uint32_t cpu=CPU_TYPE_X86_64;
#endif
        if(__builtin_bswap32(arches[i].cputype)==cpu){offset=__builtin_bswap32(arches[i].offset);found=true;break;}
      }
      if(!found||offset+sizeof(struct mach_header_64)>(size_t)st.st_size){munmap(map,(size_t)st.st_size);return false;}
    }
    struct mach_header_64 *h=(struct mach_header_64*)(map+offset);
    bool ok=h->magic==MH_MAGIC_64 && h->ncmds<=4096 && offset+sizeof(*h)+h->sizeofcmds<=(size_t)st.st_size;
    size_t pos=offset+sizeof(*h);
    for(uint32_t i=0;ok&&i<h->ncmds;i++) {
      if(pos+sizeof(struct load_command)>(size_t)st.st_size){ok=false;break;}
      struct load_command *lc=(struct load_command*)(map+pos);
      if(lc->cmdsize<sizeof(*lc)||pos+lc->cmdsize>(size_t)st.st_size){ok=false;break;}
      if(lc->cmd==LC_LOAD_DYLIB||lc->cmd==LC_LOAD_WEAK_DYLIB||lc->cmd==LC_REEXPORT_DYLIB||lc->cmd==LC_LOAD_UPWARD_DYLIB) {
        struct dylib_command *d=(struct dylib_command*)lc;
        if(lc->cmdsize<sizeof(*d)||d->dylib.name.offset>=lc->cmdsize){ok=false;break;}
        const char *p=(char*)lc+d->dylib.name.offset;
        if(!memchr(p,0,lc->cmdsize-d->dylib.name.offset)){ok=false;break;}
        if(!system_library(p)) {
          char path[PATH_MAX];
          if(!strncmp(p,"@loader_path/",13)) {
            char dir[PATH_MAX];snprintf(dir,sizeof(dir),"%s",libs.p[at]);char *slash=strrchr(dir,'/');*slash=0;
            if(snprintf(path,sizeof(path),"%s/%s",dir,p+13)>=(int)sizeof(path)) {ok=false;break;}p=path;
          }
          if(*p!='/'||!add_path(p)){ok=false;break;}
        }
      }
      pos+=lc->cmdsize;
    }
    munmap(map,(size_t)st.st_size);if(!ok)return false;
  }
  return true;
}
static bool profile_quote(FILE *f,const char *p) {
  if(fputc('"',f)==EOF)return false;
  for(;*p;p++){if(*p=='"'||*p=='\\') fputc('\\',f);if((unsigned char)*p<32)return false;fputc(*p,f);}return fputc('"',f)!=EOF;
}
static char *mac_profile(const struct options *o) {
  char *profile=NULL;size_t size=0;FILE *f=open_memstream(&profile,&size);if(!f)return NULL;
  fputs("(version 1)(deny default)(allow process-exec)(deny process-fork)(deny network*)"
    "(allow sysctl-read)(allow file-read-metadata)"
    "(allow file-read* (literal \"/\"))"
    "(allow file-read* (subpath \"/System/Library\") (subpath \"/usr/lib\") (subpath \"/private/var/db/dyld\"))"
    "(allow file-read* file-write* (subpath ",f);
  bool ok=profile_quote(f,o->workdir);fputs("))",f);
  for(size_t i=0;ok&&i<libs.count;i++){fputs("(allow file-read* (literal ",f);ok=profile_quote(f,libs.p[i]);fputs("))",f);}
  fputs("(allow file-read* file-write* (literal \"/dev/null\"))",f);
  if(fclose(f)||!ok){free(profile);return NULL;}return profile;
}
#endif

/* Cleanup evidence lives beside the writable worker directory, never inside it.
 * The private parent descriptor is not inherited by the exec'd worker. */
static int marker_parent(const struct options *o,char *name,size_t capacity) {
  char parent[PATH_MAX];snprintf(parent,sizeof(parent),"%s",o->workdir);
  char *base=strrchr(parent,'/');if(!base||!base[1])return -1;
  if(snprintf(name,capacity,"%s.cleanup-confirmed",base+1)>=(int)capacity)return -1;
  *base=0;if(!parent[0])return -1;
  int fd=open(parent,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
  if(fd<0)return -1;
  if(fstat(fd,&st)||st.st_uid!=geteuid()||(st.st_mode&0077)){close(fd);return -1;}
  return fd;
}
static bool cleanup_marker(const struct options *o,bool create) {
  char name[NAME_MAX+1];int parent=marker_parent(o,name,sizeof(name));if(parent<0)return false;
  bool ok;
  if(!create){ok=unlinkat(parent,name,0)==0||errno==ENOENT;close(parent);return ok;}
  char tmp[NAME_MAX+1];
  if(snprintf(tmp,sizeof(tmp),".audio-cleanup-%ld",(long)getpid())>=(int)sizeof(tmp)){close(parent);return false;}
  int fd=openat(parent,tmp,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0){close(parent);return false;}
  ok=write_all(fd,"clean\n",6)&&fsync(fd)==0;close(fd);
  if(ok)ok=renameat(parent,tmp,parent,name)==0;
  if(!ok)unlinkat(parent,tmp,0);
  close(parent);return ok;
}

/* Executed only by selftest under the exact same sandbox used for media. */
static void *held_thread(void *ignored) { (void)ignored; for(;;)pause(); return NULL; }
static int internal_test(const char *mode) {
  if(!strcmp(mode,"--internal-thread-flood")) {
    pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,65536);
    for(int i=0;i<128;i++){pthread_t thread;if(pthread_create(&thread,&attr,held_thread,NULL))return 0;}
    pthread_attr_destroy(&attr);for(;;)pause();
  }
  if(!strcmp(mode,"--internal-hold")) {for(;;)pause();}
  if(!strcmp(mode,"--internal-flood")) {char b[1024];memset(b,'x',sizeof(b));for(int i=0;i<64;i++)(void)write_all(2,b,sizeof(b));return 0;}
  if(!strcmp(mode,"--internal-large-file")) {int fd=open("large",O_CREAT|O_WRONLY,0600);if(fd<0)return 40;char b[4096]={0};for(int i=0;i<100;i++)if(!write_all(fd,b,sizeof(b)))return 41;close(fd);return 42;}
  if(strcmp(mode,"--internal-selftest")) return 90;
  if(getenv("AUDIO_TEST_SECRET")) return 10;
#ifdef __linux__
  if(kill(getppid(),0)!=-1||errno!=EPERM)return 20;
#endif
  char cwd[PATH_MAX],sidecar[PATH_MAX];
  if(!getcwd(cwd,sizeof(cwd))||snprintf(sidecar,sizeof(sidecar),"%s.cleanup-confirmed",cwd)>=(int)sizeof(sidecar))return 18;
  int sidefd=open(sidecar,O_CREAT|O_WRONLY,0600);
  if(sidefd>=0){close(sidefd);unlink(sidecar);return 19;}
  int fd=open("/etc/passwd",O_RDONLY);if(fd>=0){close(fd);return 11;}
  fd=open("/tmp/backplane-audio-outside",O_CREAT|O_WRONLY,0600);if(fd>=0){close(fd);unlink("/tmp/backplane-audio-outside");return 12;}
  fd=socket(AF_INET,SOCK_STREAM,0);
  if(fd>=0){
    struct sockaddr_in addr={0};addr.sin_family=AF_INET;addr.sin_port=htons(9);addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int result=connect(fd,(struct sockaddr*)&addr,sizeof(addr));int saved=errno;close(fd);
    if(result==0||(saved!=EPERM&&saved!=EACCES))return 13;
  }
  pid_t p=fork();if(p==0)_exit(0);if(p>0){waitpid(p,NULL,0);return 14;}
  if(setsid()!=-1||setpgid(0,0)!=-1)return 15;
  fd=open("selftest",O_CREAT|O_WRONLY|O_EXCL,0600);if(fd<0)return 16;
  bool ok=write_all(fd,"confined",8);close(fd);unlink("selftest");return ok?0:17;
}

static void worker(const struct options *o,int errfd,int execfd,pid_t guardian) {
  /* fd3 is a CLOEXEC handshake. EOF establishes successful first exec; any byte
   * identifies setup failure before S is published. */
  if(execfd!=3){if(dup2(execfd,3)<0)_exit(125);}fcntl(3,F_SETFD,FD_CLOEXEC);
  if(dup2(errfd,2)<0)_exit(125);
  int null=open("/dev/null",O_RDWR);if(null<0||dup2(null,0)<0||dup2(null,1)<0)_exit(125);close_above(4);
  unsigned char reason='s';
  if(setsid()<0||chdir(o->workdir)||!limits(o))goto failed;
  umask(0077);
#ifdef __linux__
  if(prctl(PR_SET_PDEATHSIG,SIGKILL)||getppid()!=guardian)goto failed;
  if(!filesystem_sandbox(o)||!syscall_sandbox()){reason='b';goto failed;}
  execve(o->executable,o->args,safe_env);
#else
  (void)guardian;
  char *profile=mac_profile(o);if(!profile){reason='b';goto failed;}
  size_t argc=0;while(o->args[argc])argc++;
  char **args=calloc(argc+4,sizeof(char*));if(!args){free(profile);goto failed;}
  args[0]="/usr/bin/sandbox-exec";args[1]="-p";args[2]=profile;
  for(size_t i=0;i<argc;i++)args[i+3]=o->args[i];
  execve(args[0],args,safe_env);free(args);free(profile);reason='b';
#endif
failed:
  (void)write_all(3,&reason,1);_exit(125);
}

static int guard(const struct options *o,int lifeline) {
  int diag[2],execpipe[2];if(pipe(diag)||pipe(execpipe)){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  pid_t guardian_pid=getpid();
  pid_t pid=fork();if(pid<0){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  if(!pid)worker(o,diag[1],execpipe[1],guardian_pid);
  close(diag[1]);close(execpipe[1]);fcntl(diag[0],F_SETFL,O_NONBLOCK);fcntl(execpipe[0],F_SETFL,O_NONBLOCK);
  fcntl(0,F_SETFL,O_NONBLOCK);fcntl(lifeline,F_SETFL,O_NONBLOCK);
  unsigned char ring[MAX_DIAG];size_t used=0,head=0;unsigned char control[5];size_t control_used=0;
  uint64_t deadline=now_ms()+o->deadline,kill_at=0,cleanup_deadline=0;const char *failure=NULL;
  bool started=false,terminated=false,reaped=false;int status=-1;
  for(;;) {
    struct pollfd fds[]={{0,POLLIN,0},{lifeline,POLLIN,0},{diag[0],POLLIN,0},{execpipe[0],POLLIN,0}};
    (void)poll(fds,4,20);
    /* Drain diagnostics even when cancellation is pending; retain only tail. */
    unsigned char buf[2048];ssize_t n;
    while((n=read(diag[0],buf,sizeof(buf)))>0) {
      for(ssize_t i=0;i<n;i++)if(o->stderr_max){ring[head]=buf[i];head=(head+1)%o->stderr_max;if(used<o->stderr_max)used++;}
    }
    if(!started&&!failure) {
      unsigned char why;ssize_t result=read(execpipe[0],&why,1);
      if(result==0){started=true;unsigned char s[9]={'S'};be32(s+1,(uint32_t)pid);be32(s+5,(uint32_t)pid);frame(s,9);}
      else if(result>0)failure=why=='b'?"sandbox_unavailable":"spawn_failed";
    }
    if(!failure) {
      ssize_t result=read(lifeline,buf,1);
      if(result==0)failure="cancelled";
      else {
        result=read(0,control+control_used,sizeof(control)-control_used);
        if(result==0)failure="cancelled";
        else if(result>0){control_used+=(size_t)result;if(control_used==5)failure="cancelled";}
      }
    }
    /* Sample per-worker threads every poll on both platforms. Linux retains
     * hard RLIMIT_AS; Darwin additionally samples resident memory. */
    if(!failure&&started)failure=worker_resource_failure(pid);
    if(!failure&&now_ms()>=deadline)failure="timeout";
    if(failure&&!terminated){kill(-pid,SIGTERM);kill(pid,SIGTERM);terminated=true;kill_at=now_ms()+150;cleanup_deadline=now_ms()+2000;}
    if(terminated&&now_ms()>=kill_at){kill(-pid,SIGKILL);kill(pid,SIGKILL);kill_at=UINT64_MAX;}
    siginfo_t info={0};
    if(waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT)==0&&info.si_pid==pid) {
      /* Hold the unreaped leader as a PID/PGID reuse guard until final group kill.
       * Sandboxed media cannot fork; any pre-exec failure has no descendants. */
      kill(-pid,SIGKILL);
      pid_t w;do{w=waitpid(pid,&status,0);}while(w<0&&errno==EINTR);reaped=w==pid;break;
    }
    if(terminated&&kill_at==UINT64_MAX&&now_ms()>cleanup_deadline){failure="cleanup_uncertain";break;}
  }
  /* A final drain after reap captures the child's last diagnostic bytes. */
  unsigned char buf[2048];ssize_t n;while((n=read(diag[0],buf,sizeof(buf)))>0)for(ssize_t i=0;i<n;i++)if(o->stderr_max){ring[head]=buf[i];head=(head+1)%o->stderr_max;if(used<o->stderr_max)used++;}
  close(diag[0]);close(execpipe[0]);close(lifeline);
  if(used){unsigned char d[MAX_DIAG+1];d[0]='D';size_t first=used==o->stderr_max?head:0;for(size_t i=0;i<used;i++)d[i+1]=ring[(first+i)%o->stderr_max];frame(d,used+1);}
  if(reaped&&WIFSIGNALED(status)&&WTERMSIG(status)==SIGXFSZ&&!failure)failure="output_limit";
  if(reaped&&!cleanup_marker(o,true)){failure="cleanup_uncertain";reaped=false;}
  if(failure)error_frame(failure);
  exit_frame(status,reaped);return reaped?0:1;
}

static bool positive(const char *s,uint64_t *out) {if(!s||!*s||*s=='-')return false;char *end;errno=0;unsigned long long n=strtoull(s,&end,10);if(errno||*end||!n)return false;*out=n;return true;}
static bool options(int argc,char **argv,struct options *o) {
  memset(o,0,sizeof(*o));int i=1;const char *work=NULL;
  for(;i<argc&&strcmp(argv[i],"--");i+=2){if(i+1>=argc)return false;uint64_t n;
    if(!strcmp(argv[i],"--mode"))o->mode=argv[i+1];
    else if(!strcmp(argv[i],"--workdir"))work=argv[i+1];
    else if(!strcmp(argv[i],"--deadline-ms")){if(!positive(argv[i+1],&n)||n>3600000)return false;o->deadline=n;}
    else if(!strcmp(argv[i],"--max-file-bytes")){if(!positive(argv[i+1],&n)||n>INT64_MAX)return false;o->max_file=(rlim_t)n;}
    else if(!strcmp(argv[i],"--stderr-bytes")){if(!strcmp(argv[i+1],"0"))n=0;else if(!positive(argv[i+1],&n))return false;if(n>MAX_DIAG)return false;o->stderr_max=(size_t)n;}
    else return false;
  }
  if(i+1>=argc||!work||work[0]!='/'||!o->mode||!o->deadline||!o->max_file)return false;
  if(strcmp(o->mode,"probe")&&strcmp(o->mode,"convert")&&strcmp(o->mode,"selftest"))return false;
  struct stat st;if(!realpath(work,o->workdir)||stat(o->workdir,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&0077))return false;
  if(argv[i+1][0]!='/'||!realpath(argv[i+1],o->executable)||access(o->executable,X_OK))return false;
  o->args=argv+i+1;o->args[0]=o->executable;
#ifdef __linux__
  ssize_t n=readlink("/proc/self/exe",o->self,sizeof(o->self)-1);if(n<=0)return false;o->self[n]=0;
#else
  uint32_t size=sizeof(o->self);char path[PATH_MAX];if(_NSGetExecutablePath(path,&size)||!realpath(path,o->self))return false;
#endif
  if(!strcmp(o->mode,"selftest")){snprintf(o->executable,sizeof(o->executable),"%s",o->self);static char *test_args[3];test_args[0]=o->executable;test_args[1]="--internal-selftest";o->args=test_args;}
  return true;
}
int main(int argc,char **argv) {
  if(argc==2&&!strncmp(argv[1],"--internal-",11))return internal_test(argv[1]);
  signal(SIGPIPE,SIG_IGN);close_above(3);
  struct options o;if(!options(argc,argv,&o)){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  if(!cleanup_marker(&o,false)){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  if(!dependencies(o.executable)){error_frame("sandbox_unavailable");exit_frame(125<<8,true);return 1;}
  int life[2];if(pipe(life)){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  pid_t guardian=fork();if(guardian<0){error_frame("spawn_failed");exit_frame(125<<8,true);return 1;}
  if(!guardian){close(life[1]);int result=guard(&o,life[0]);_exit(result);}
  /* Parent never reads BEAM stdin. Only its private lifeline write end survives. */
  close(life[0]);close(0);close(1);close(2);int status;pid_t result;
  do{result=waitpid(guardian,&status,0);}while(result<0&&errno==EINTR);close(life[1]);return result==guardian&&WIFEXITED(status)?WEXITSTATUS(status):1;
}
