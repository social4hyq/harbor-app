/* harbor_bridge.c — 通用 NAPI 桥（纯 C）：fork+setsid+execve 拉起任意外部 ELF
 * 接口：spawn(binPath, argsJson, logPath, pidfile) -> number (1=started, 0=already running)
 * 去重：pidfile 记录 pid，kill(pid,0) 探测存活（纯 syscall，不用 stdio 避免 C++ Crash）
 */
#include <napi/native_api.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#define MAX_ARGS 16
#define ARG_CAP  2048
#define MAX_ENVS 24

static void get_str(napi_env env, napi_value v, char *out, size_t cap) {
  size_t len = 0;
  napi_get_value_string_utf8(env, v, out, cap, &len);
}

/* 极简 JSON 字符串数组解析：["a", "b", ...] -> argv[][]，返回参数个数 */
static int parse_args_json(const char *json, char argv[][ARG_CAP], int max) {
  int n = 0;
  const char *p = json;
  while (*p && n < max) {
    while (*p && *p != '"') p++;          // 找起始引号
    if (!*p) break;
    p++;                                   // 跳过 "
    char *dst = argv[n];
    size_t k = 0;
    while (*p && *p != '"' && k < ARG_CAP - 1) {
      if (*p == '\\' && *(p + 1)) {        // 处理转义 \" \\ \/ \n
        p++;
        char c = (*p == 'n') ? '\n' : (*p == 't') ? '\t' : *p;
        dst[k++] = c;
        p++;
      } else {
        dst[k++] = *p++;
      }
    }
    dst[k] = '\0';
    n++;
    if (*p == '"') p++;
    while (*p && *p != '"') p++;          // 移到下一个引号或结尾
  }
  return n;
}

/* 极简 JSON 对象解析：{"KEY":"VAL", ...} -> "KEY=VAL" 字符串数组，返回个数
 * 用于环境变量注入。值中不支持嵌套对象/数组，仅字符串。 */
static int parse_env_json(const char *json, char envp[][ARG_CAP], int max) {
  int n = 0;
  const char *p = json;
  while (*p && n < max) {
    while (*p && *p != '"') p++;          // key 起始引号
    if (!*p) break;
    p++;
    char key[512] = {0};
    size_t k = 0;
    while (*p && *p != '"' && k < sizeof(key) - 1) key[k++] = *p++;
    key[k] = '\0';
    if (*p == '"') p++;
    while (*p && *p != ':') p++;          // 冒号
    if (*p == ':') p++;
    while (*p && *p != '"') p++;          // value 起始引号
    if (!*p) break;
    p++;
    char *dst = envp[n];
    size_t m = 0;
    // 写入 KEY=
    for (size_t i = 0; i < k && m < ARG_CAP - 1; i++) dst[m++] = key[i];
    if (m < ARG_CAP - 1) dst[m++] = '=';
    while (*p && *p != '"' && m < ARG_CAP - 1) {
      if (*p == '\\' && *(p + 1)) {
        p++;
        char c = (*p == 'n') ? '\n' : (*p == 't') ? '\t' : *p;
        dst[m++] = c;
        p++;
      } else {
        dst[m++] = *p++;
      }
    }
    dst[m] = '\0';
    n++;
    if (*p == '"') p++;
    while (*p && *p != ',') p++;          // 下一个键值或结尾
    if (*p == ',') p++;
  }
  return n;
}

/* pidfile 去重：读 pid，kill(pid,0) 存活则返回 1 */
static int pidfile_alive(const char *pidfile) {
  int fd = open(pidfile, O_RDONLY);
  if (fd < 0) return 0;
  char buf[32] = {0};
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return 0;
  pid_t old = (pid_t)atoi(buf);
  if (old <= 1) return 0;
  return kill(old, 0) == 0;   // 0=存活；-1 EPERM 说明存在但非本 uid，也算存活
}

/* 递归创建目录（mkdir -p），忽略已存在 */
static void mkdir_p(const char *path) {
  char tmp[1024];
  size_t n = strlen(path);
  if (n == 0 || n >= sizeof(tmp)) return;
  memcpy(tmp, path, n + 1);
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = '\0';
      mkdir(tmp, 0755);
      *p = '/';
    }
  }
  mkdir(tmp, 0755);
}

/* 对文件路径取父目录并 mkdir -p */
static void ensure_parent_dir(const char *filepath) {
  char dir[1024];
  size_t n = strlen(filepath);
  if (n == 0 || n >= sizeof(dir)) return;
  memcpy(dir, filepath, n + 1);
  char *slash = strrchr(dir, '/');
  if (slash && slash != dir) {
    *slash = '\0';
    mkdir_p(dir);
  }
}

/* 孙进程写自己的 pidfile（纯 syscall） */
static void write_pidfile(const char *pidfile) {
  int fd = open(pidfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  char buf[32];
  int len = snprintf(buf, sizeof(buf), "%d", (int)getpid());
  if (len > 0) write(fd, buf, (size_t)len);
  close(fd);
}

/* spawn(binPath, argsJson, logPath, pidfile, envJson) -> number
 * envJson 可选：{"KEY":"VAL",...} 注入环境变量（bash/bun 等需要） */
static napi_value Spawn(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 4) {
    napi_throw_error(env, NULL, "spawn needs (binPath, argsJson, logPath, pidfile[, envJson])");
    return NULL;
  }
  char bin[1024], args_json[8192], log[1024], pidfile[1024], env_json[8192] = {0};
  get_str(env, args[0], bin, sizeof(bin));
  get_str(env, args[1], args_json, sizeof(args_json));
  get_str(env, args[2], log, sizeof(log));
  get_str(env, args[3], pidfile, sizeof(pidfile));
  if (argc >= 5) get_str(env, args[4], env_json, sizeof(env_json));

  // 去重：pidfile 存活则跳过
  if (pidfile[0] && pidfile_alive(pidfile)) {
    napi_value ret;
    napi_create_int32(env, 0, &ret);   // 0 = already running
    return ret;
  }

  if (access(bin, X_OK) != 0) {
    char msg[1200];
    snprintf(msg, sizeof(msg), "not executable: %s errno=%d", bin, errno);
    napi_throw_error(env, NULL, msg);
    return NULL;
  }

  char argv[MAX_ARGS][ARG_CAP];
  int argc_n = parse_args_json(args_json, argv, MAX_ARGS);
  char *argvp[MAX_ARGS + 2];
  argvp[0] = bin;
  for (int i = 0; i < argc_n; i++) argvp[i + 1] = argv[i];
  argvp[argc_n + 1] = NULL;

  pid_t pid = fork();
  if (pid < 0) {
    napi_throw_error(env, NULL, "fork failed");
    return NULL;
  }
  if (pid == 0) {
    setsid();
    pid_t pid2 = fork();
    if (pid2 < 0) _exit(1);
    if (pid2 > 0) _exit(0);  // 中间进程退出，孙进程被 init 收养
    if (pidfile[0]) { ensure_parent_dir(pidfile); write_pidfile(pidfile); }
    if (log[0]) ensure_parent_dir(log);
    int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
      dup2(fd, 1); dup2(fd, 2);
      if (fd > 2) close(fd);
    }
    // 构造环境变量数组（来自 envJson），未注入时用空环境
    char envbuf[MAX_ENVS][ARG_CAP];
    int envn = env_json[0] ? parse_env_json(env_json, envbuf, MAX_ENVS) : 0;
    char *envp[MAX_ENVS + 1];
    for (int i = 0; i < envn; i++) envp[i] = envbuf[i];
    envp[envn] = NULL;
    execve(bin, argvp, envp);
    _exit(127);
  }
  int status;
  waitpid(pid, &status, 0);
  napi_value ret;
  napi_create_int32(env, 1, &ret);   // 1 = started
  return ret;
}

/* pidFromPidfile(pidfile) -> pid (number)，进程已死或文件无效返回 0 */
static napi_value PidFromPidfile(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 1) { napi_throw_error(env, NULL, "pidFromPidfile needs pidfile"); return NULL; }
  char pidfile[1024];
  get_str(env, args[0], pidfile, sizeof(pidfile));
  int pid = 0;
  int fd = open(pidfile, O_RDONLY);
  if (fd >= 0) {
    char buf[32] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n > 0) {
      int p = atoi(buf);
      if (p > 1 && kill((pid_t)p, 0) == 0) pid = p;  // 存活
    }
  }
  napi_value ret;
  napi_create_int32(env, pid, &ret);
  return ret;
}

/* killPid(pid, signal) -> number (0=ok, -1=err) */
static napi_value KillPid(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 2) { napi_throw_error(env, NULL, "killPid needs (pid, signal)"); return NULL; }
  int32_t pid = 0, sig = 15;
  napi_get_value_int32(env, args[0], &pid);
  napi_get_value_int32(env, args[1], &sig);
  int r = (pid > 1) ? kill((pid_t)pid, sig) : -1;
  napi_value ret;
  napi_create_int32(env, r, &ret);
  return ret;
}

/* pidfileExists(pidfile) -> number (1=文件存在, 0=不存在) */
static napi_value PidfileExists(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 1) { napi_throw_error(env, NULL, "pidfileExists needs pidfile"); return NULL; }
  char pidfile[1024];
  get_str(env, args[0], pidfile, sizeof(pidfile));
  napi_value ret;
  napi_create_int32(env, access(pidfile, F_OK) == 0 ? 1 : 0, &ret);
  return ret;
}

/* cleanupPidfiles(dir, keepJson) -> number (删除的个数)
 * 扫描 dir 下所有 *.pid，删除 basename(去掉.pid) 不在 keepJson 数组里的。
 * 用于 HAP 启动时清理已移除服务的残留 pidfile。 */
static napi_value CleanupPidfiles(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 2) { napi_throw_error(env, NULL, "cleanupPidfiles needs (dir, keepJson)"); return NULL; }
  char dir[1024], keep_json[8192];
  get_str(env, args[0], dir, sizeof(dir));
  get_str(env, args[1], keep_json, sizeof(keep_json));

  // 解析 keepJson 字符串数组到 keep[]（复用 parse_args_json）
  char keep[MAX_ARGS][ARG_CAP];
  int keep_n = parse_args_json(keep_json, keep, MAX_ARGS);

  int removed = 0;
  DIR *dp = opendir(dir);
  if (!dp) {
    napi_value ret; napi_create_int32(env, 0, &ret); return ret;  // 目录不存在，无需清理
  }
  struct dirent *ent;
  while ((ent = readdir(dp)) != NULL) {
    const char *name = ent->d_name;
    size_t len = strlen(name);
    if (len < 4 || strcmp(name + len - 4, ".pid") != 0) continue;  // 只处理 .pid
    char base[512];
    size_t blen = len - 4;
    if (blen >= sizeof(base)) continue;
    memcpy(base, name, blen); base[blen] = '\0';
    int in_keep = 0;
    for (int i = 0; i < keep_n; i++) {
      if (strcmp(keep[i], base) == 0) { in_keep = 1; break; }
    }
    if (!in_keep) {
      char full[1200];
      snprintf(full, sizeof(full), "%s/%s", dir, name);
      if (unlink(full) == 0) removed++;
    }
  }
  closedir(dp);
  napi_value ret; napi_create_int32(env, removed, &ret); return ret;
}

/* killAndWait(pid, signal, timeoutMs) -> number (0=进程已退出, -1=超时/失败)
 * kill 后轮询等待进程真正退出，解决 SIGTERM 异步导致 restart 竞态（spawn 去重误判“仍在运行”） */
static napi_value KillAndWait(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc < 3) { napi_throw_error(env, NULL, "killAndWait needs (pid, signal, timeoutMs)"); return NULL; }
  int32_t pid = 0, sig = 15, timeout_ms = 2000;
  napi_get_value_int32(env, args[0], &pid);
  napi_get_value_int32(env, args[1], &sig);
  napi_get_value_int32(env, args[2], &timeout_ms);
  if (pid <= 1) { napi_value r; napi_create_int32(env, -1, &r); return r; }
  kill((pid_t)pid, sig);
  // 轮询：每 20ms 检查一次，直到 kill(pid,0) 失败（进程退出）或超时
  struct timespec ts = { 0, 20000000 };  // 20ms
  int elapsed = 0;
  while (elapsed < timeout_ms) {
    if (kill((pid_t)pid, 0) != 0) {       // 进程已退出
      napi_value r; napi_create_int32(env, 0, &r); return r;
    }
    nanosleep(&ts, NULL);
    elapsed += 20;
  }
  napi_value r; napi_create_int32(env, -1, &r); return r;  // 超时
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    { "spawn", NULL, Spawn, NULL, NULL, NULL, napi_default, NULL },
    { "pidFromPidfile", NULL, PidFromPidfile, NULL, NULL, NULL, napi_default, NULL },
    { "killPid", NULL, KillPid, NULL, NULL, NULL, napi_default, NULL },
    { "killAndWait", NULL, KillAndWait, NULL, NULL, NULL, napi_default, NULL },
    { "pidfileExists", NULL, PidfileExists, NULL, NULL, NULL, napi_default, NULL },
    { "cleanupPidfiles", NULL, CleanupPidfiles, NULL, NULL, NULL, napi_default, NULL }
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module daemonModule = {
  1, 0, NULL, Init, "libharbor_bridge.so", NULL, { 0, 0, 0, 0 }
};

__attribute__((constructor)) void RegisterDaemonModule(void) {
  napi_module_register(&daemonModule);
}
