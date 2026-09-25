/* curse: static libc symbol table so ffi.C resolves in a fully-static binary
 * (glibc dlsym is inoperative there). lj_clib.c falls back here. No headers —
 * symbols are referenced address-only (extern char[]) to avoid proto conflicts;
 * the linker resolves each to the real function/data address. Generated. */
extern char **environ;
extern char accept[];
extern char access[];
extern char bind[];
extern char chdir[];
extern char chmod[];
extern char clock_gettime[];
extern char close[];
extern char closedir[];
extern char confstr[];
extern char __ctype_get_mb_cur_max[];
extern char dup[];
extern char dup2[];
extern char endpwent[];
extern char _exit[];
extern char fclose[];
extern char fcntl[];
extern char flock[];
extern char fopen[];
extern char fork[];
extern char free[];
extern char getcwd[];
extern char getegid[];
extern char geteuid[];
extern char get_nprocs[];
extern char getpid[];
extern char getppid[];
extern char getpwent[];
extern char getpwnam[];
extern char getpwuid[];
extern char getrlimit[];
extern char getsockopt[];
extern char gettimeofday[];
extern char getuid[];
extern char isatty[];
extern char iswprint[];
extern char kill[];
extern char listen[];
extern char lstat[];
extern char mbrtowc[];
extern char mkdir[];
extern char open[];
extern char opendir[];
extern char pipe[];
extern char poll[];
extern char posix_spawnattr_destroy[];
extern char posix_spawnattr_init[];
extern char posix_spawnattr_setflags[];
extern char posix_spawnattr_setsigmask[];
extern char posix_spawn_file_actions_addclose[];
extern char posix_spawn_file_actions_adddup2[];
extern char posix_spawn_file_actions_destroy[];
extern char posix_spawn_file_actions_init[];
extern char posix_spawnp[];
extern char read[];
extern char readdir[];
extern char recvmsg[];
extern char regcomp[];
extern char regexec[];
extern char regfree[];
extern char setenv[];
extern char setlocale[];
extern char setpwent[];
extern char setrlimit[];
extern char setsockopt[];
extern char sigaddset[];
extern char sigemptyset[];
extern char sigprocmask[];
extern char sigtimedwait[];
extern char socket[];
extern char stat[];
extern char strcoll[];
extern char strtoll[];
extern char strtoull[];
extern char towlower[];
extern char towupper[];
extern char ttyname[];
extern char umask[];
extern char unlink[];
extern char unsetenv[];
extern char waitpid[];
extern char wcrtomb[];
extern char write[];
/* curse async signal primitives (defined in lib_cursesig.c; address-only refs). */
extern char curse_sig_catch[];
extern char curse_sig_default[];
extern char curse_sig_ignore[];
extern char curse_sig_clearpending[];
extern char curse_sig_hold[];
extern char curse_ldfmt[];
extern char curse_preempt_flagp[];
extern char curse_preempt_arm[];
extern char __fpurge[];
extern char clearenv[];
extern char clearerr[];
extern char execve[];
extern char fstat[];
extern char sigaction[];
extern char tee[];
extern char getrusage[];
extern char ioctl[];
extern char iswctype[];
extern char iswupper[];
extern char localeconv[];
extern char lseek[];
extern char malloc[];
extern char mmap[];
extern char pipe2[];
extern char posix_spawn_file_actions_addopen[];
extern char stdin[];
extern char strerror[];
extern char strxfrm[];
extern char syscall[];
extern char wcscoll[];
extern char wctype[];
extern char wcwidth[];
typedef struct { const char *name; void *addr; } curse_sym_t;
static const curse_sym_t curse_syms[] = {
  { "environ", (void*)&environ },
  { "curse_sig_catch", (void*)curse_sig_catch },
  { "curse_sig_default", (void*)curse_sig_default },
  { "curse_sig_ignore", (void*)curse_sig_ignore },
  { "curse_sig_clearpending", (void*)curse_sig_clearpending },
  { "curse_sig_hold", (void*)curse_sig_hold },
  { "curse_ldfmt", (void*)curse_ldfmt },
  { "curse_preempt_flagp", (void*)curse_preempt_flagp },
  { "curse_preempt_arm", (void*)curse_preempt_arm },
  { "accept", (void*)accept },
  { "access", (void*)access },
  { "bind", (void*)bind },
  { "chdir", (void*)chdir },
  { "chmod", (void*)chmod },
  { "clock_gettime", (void*)clock_gettime },
  { "close", (void*)close },
  { "closedir", (void*)closedir },
  { "confstr", (void*)confstr },
  { "__ctype_get_mb_cur_max", (void*)__ctype_get_mb_cur_max },
  { "dup", (void*)dup },
  { "dup2", (void*)dup2 },
  { "endpwent", (void*)endpwent },
  { "_exit", (void*)_exit },
  { "fclose", (void*)fclose },
  { "fcntl", (void*)fcntl },
  { "flock", (void*)flock },
  { "fopen", (void*)fopen },
  { "fork", (void*)fork },
  { "free", (void*)free },
  { "getcwd", (void*)getcwd },
  { "getegid", (void*)getegid },
  { "geteuid", (void*)geteuid },
  { "get_nprocs", (void*)get_nprocs },
  { "getpid", (void*)getpid },
  { "getppid", (void*)getppid },
  { "getpwent", (void*)getpwent },
  { "getpwnam", (void*)getpwnam },
  { "getpwuid", (void*)getpwuid },
  { "getrlimit", (void*)getrlimit },
  { "getsockopt", (void*)getsockopt },
  { "gettimeofday", (void*)gettimeofday },
  { "getuid", (void*)getuid },
  { "isatty", (void*)isatty },
  { "iswprint", (void*)iswprint },
  { "kill", (void*)kill },
  { "listen", (void*)listen },
  { "lstat", (void*)lstat },
  { "mbrtowc", (void*)mbrtowc },
  { "mkdir", (void*)mkdir },
  { "open", (void*)open },
  { "opendir", (void*)opendir },
  { "pipe", (void*)pipe },
  { "poll", (void*)poll },
  { "posix_spawnattr_destroy", (void*)posix_spawnattr_destroy },
  { "posix_spawnattr_init", (void*)posix_spawnattr_init },
  { "posix_spawnattr_setflags", (void*)posix_spawnattr_setflags },
  { "posix_spawnattr_setsigmask", (void*)posix_spawnattr_setsigmask },
  { "posix_spawn_file_actions_addclose", (void*)posix_spawn_file_actions_addclose },
  { "posix_spawn_file_actions_adddup2", (void*)posix_spawn_file_actions_adddup2 },
  { "posix_spawn_file_actions_destroy", (void*)posix_spawn_file_actions_destroy },
  { "posix_spawn_file_actions_init", (void*)posix_spawn_file_actions_init },
  { "posix_spawnp", (void*)posix_spawnp },
  { "read", (void*)read },
  { "readdir", (void*)readdir },
  { "recvmsg", (void*)recvmsg },
  { "regcomp", (void*)regcomp },
  { "regexec", (void*)regexec },
  { "regfree", (void*)regfree },
  { "setenv", (void*)setenv },
  { "setlocale", (void*)setlocale },
  { "setpwent", (void*)setpwent },
  { "setrlimit", (void*)setrlimit },
  { "setsockopt", (void*)setsockopt },
  { "sigaddset", (void*)sigaddset },
  { "sigemptyset", (void*)sigemptyset },
  { "sigprocmask", (void*)sigprocmask },
  { "sigtimedwait", (void*)sigtimedwait },
  { "socket", (void*)socket },
  { "stat", (void*)stat },
  { "strcoll", (void*)strcoll },
  { "strtoll", (void*)strtoll },
  { "strtoull", (void*)strtoull },
  { "towlower", (void*)towlower },
  { "towupper", (void*)towupper },
  { "ttyname", (void*)ttyname },
  { "umask", (void*)umask },
  { "unlink", (void*)unlink },
  { "unsetenv", (void*)unsetenv },
  { "waitpid", (void*)waitpid },
  { "wcrtomb", (void*)wcrtomb },
  { "write", (void*)write },
  { "__fpurge", (void*)__fpurge },
  { "clearenv", (void*)clearenv },
  { "clearerr", (void*)clearerr },
  { "execve", (void*)execve },
  { "fstat", (void*)fstat },
  { "sigaction", (void*)sigaction },
  { "tee", (void*)tee },
  { "getrusage", (void*)getrusage },
  { "ioctl", (void*)ioctl },
  { "iswctype", (void*)iswctype },
  { "iswupper", (void*)iswupper },
  { "localeconv", (void*)localeconv },
  { "lseek", (void*)lseek },
  { "malloc", (void*)malloc },
  { "mmap", (void*)mmap },
  { "pipe2", (void*)pipe2 },
  { "posix_spawn_file_actions_addopen", (void*)posix_spawn_file_actions_addopen },
  { "stdin", (void*)stdin },
  { "strerror", (void*)strerror },
  { "strxfrm", (void*)strxfrm },
  { "syscall", (void*)syscall },
  { "wcscoll", (void*)wcscoll },
  { "wctype", (void*)wctype },
  { "wcwidth", (void*)wcwidth },
  { 0, 0 }
};
static int streq(const char *a, const char *b){ while(*a && *a==*b){a++;b++;} return *a==*b; }
void *curse_static_sym(const char *name){
  const curse_sym_t *s; for (s = curse_syms; s->name; s++)
    if (streq(s->name, name)) return s->addr;
  return 0;
}
