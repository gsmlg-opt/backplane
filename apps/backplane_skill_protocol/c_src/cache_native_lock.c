#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

typedef struct {
  ErlNifMutex *mutex;
  int fd;
} cache_lock_t;

static ErlNifResourceType *cache_lock_resource;

static ERL_NIF_TERM error_atom(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
                          enif_make_atom(env, reason));
}

static void close_lock(cache_lock_t *lock) {
  if (lock->mutex == NULL) {
    return;
  }

  enif_mutex_lock(lock->mutex);

  if (lock->fd >= 0) {
    (void)flock(lock->fd, LOCK_UN);
    (void)close(lock->fd);
    lock->fd = -1;
  }

  enif_mutex_unlock(lock->mutex);
}

static void cache_lock_destructor(ErlNifEnv *env, void *object) {
  cache_lock_t *lock = object;
  (void)env;

  close_lock(lock);
  enif_mutex_destroy(lock->mutex);
}

static ERL_NIF_TERM acquire(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  ErlNifBinary path;
  cache_lock_t *lock;
  ERL_NIF_TERM resource_term;
  char *path_string;
  int flags = O_RDWR | O_CREAT;
  int fd;

  if (argc != 1 || !enif_inspect_binary(env, argv[0], &path) ||
      path.size == 0 || memchr(path.data, '\0', path.size) != NULL) {
    return error_atom(env, "invalid_path");
  }

  path_string = enif_alloc(path.size + 1);
  if (path_string == NULL) {
    return error_atom(env, "unavailable");
  }

  memcpy(path_string, path.data, path.size);
  path_string[path.size] = '\0';

#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif

  fd = open(path_string, flags, 0600);
  enif_free(path_string);

  if (fd < 0) {
    return error_atom(env, "unavailable");
  }

  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int lock_errno = errno;
    (void)close(fd);

    if (lock_errno == EWOULDBLOCK || lock_errno == EAGAIN) {
      return error_atom(env, "busy");
    }

    return error_atom(env, "unavailable");
  }

  lock = enif_alloc_resource(cache_lock_resource, sizeof(cache_lock_t));
  if (lock == NULL) {
    (void)flock(fd, LOCK_UN);
    (void)close(fd);
    return error_atom(env, "unavailable");
  }

  lock->mutex = NULL;
  lock->fd = -1;
  lock->mutex = enif_mutex_create("backplane_skill_protocol_cache_lock");
  if (lock->mutex == NULL) {
    (void)flock(fd, LOCK_UN);
    (void)close(fd);
    enif_release_resource(lock);
    return error_atom(env, "unavailable");
  }

  lock->fd = fd;
  resource_term = enif_make_resource(env, lock);
  enif_release_resource(lock);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), resource_term);
}

static ERL_NIF_TERM release(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  cache_lock_t *lock;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], cache_lock_resource, (void **)&lock)) {
    return enif_make_badarg(env);
  }

  close_lock(lock);
  return enif_make_atom(env, "ok");
}

static int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM load_info) {
  int flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
  (void)private_data;
  (void)load_info;

  cache_lock_resource = enif_open_resource_type(
      env, NULL, "backplane_skill_protocol_cache_lock", cache_lock_destructor,
      flags, NULL);

  return cache_lock_resource == NULL ? -1 : 0;
}

static ErlNifFunc nif_functions[] = {
    {"acquire", 1, acquire, 0},
    {"release", 1, release, 0},
};

ERL_NIF_INIT(Elixir.Backplane.SkillProtocol.Cache.NativeLock, nif_functions,
             load, NULL, NULL, NULL)
