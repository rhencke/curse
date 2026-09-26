/* curse: static libc symbol table so ffi.C resolves in a fully-static binary
 * (glibc dlsym is inoperative there). lj_clib.c falls back here. No headers —
 * symbols are referenced address-only (extern char[]) to avoid proto conflicts;
 * the linker resolves each to the real function/data address.
 * EVERY symbol curse's Lua reaches through ffi.C must be listed (by its LINK name:
 * an `asm("x")` alias needs "x"), or that call fails ONLY in the static binary.
 * `luajit tools/ffi-syms.lua links lua` prints the required set; the meson test
 * `static-ffi-syms` fails when one is missing. Keep the list sorted. */
extern char **environ;
extern char __ctype_get_mb_cur_max[];
extern char __fpurge[];
extern char _exit[];
extern char accept[];
extern char access[];
extern char bind[];
extern char chdir[];
extern char chmod[];
extern char clearenv[];
extern char clearerr[];
extern char clock_gettime[];
extern char close[];
extern char closedir[];
extern char confstr[];
extern char curse_ldfmt[];
extern char curse_preempt_arm[];
extern char curse_preempt_flagp[];
extern char curse_sig_catch[];
extern char curse_sig_clearpending[];
extern char curse_sig_default[];
extern char curse_sig_hold[];
extern char curse_sig_ignore[];
extern char dup[];
extern char dup2[];
extern char endpwent[];
extern char execve[];
extern char fchdir[];
extern char fchmod[];
extern char fclose[];
extern char fcntl[];
extern char flock[];
extern char fopen[];
extern char fork[];
extern char free[];
extern char fstat[];
extern char get_nprocs[];
extern char getcwd[];
extern char getegid[];
extern char geteuid[];
extern char getgid[];
extern char getgroups[];
extern char getpeername[];
extern char getpid[];
extern char getppid[];
extern char getpwent[];
extern char getpwnam[];
extern char getpwuid[];
extern char getrlimit[];
extern char getrusage[];
extern char getsockopt[];
extern char gettimeofday[];
extern char getuid[];
extern char iconv[];
extern char iconv_open[];
extern char ioctl[];
extern char isatty[];
extern char iswctype[];
extern char iswprint[];
extern char iswupper[];
extern char kill[];
extern char listen[];
extern char localeconv[];
extern char lseek[];
extern char lstat[];
extern char malloc[];
extern char mbrtowc[];
extern char mkdir[];
extern char mkstemp[];
extern char mmap[];
extern char nl_langinfo[];
extern char open[];
extern char opendir[];
extern char pipe[];
extern char pipe2[];
extern char poll[];
extern char posix_spawn[];
extern char posix_spawn_file_actions_addclose[];
extern char posix_spawn_file_actions_adddup2[];
extern char posix_spawn_file_actions_addopen[];
extern char posix_spawn_file_actions_destroy[];
extern char posix_spawn_file_actions_init[];
extern char posix_spawnattr_destroy[];
extern char posix_spawnattr_init[];
extern char posix_spawnattr_setflags[];
extern char posix_spawnattr_setsigmask[];
extern char posix_spawnp[];
extern char ppoll[];
extern char prctl[];
extern char read[];
extern char readdir[];
extern char recvmsg[];
extern char regcomp[];
extern char regexec[];
extern char regfree[];
extern char setenv[];
extern char setlocale[];
extern char setpgid[];
extern char setpwent[];
extern char setrlimit[];
extern char setsockopt[];
extern char sigaction[];
extern char sigaddset[];
extern char sigemptyset[];
extern char sigprocmask[];
extern char sigtimedwait[];
extern char socket[];
extern char stat[];
extern char stdin[];
extern char strcoll[];
extern char strdup[];
extern char strerror[];
extern char strerrordesc_np[];
extern char strtoll[];
extern char strtoull[];
extern char strxfrm[];
extern char syscall[];
extern char tee[];
extern char tolower[];
extern char toupper[];
extern char towlower[];
extern char towupper[];
extern char ttyname[];
extern char tzset[];
extern char umask[];
extern char unlink[];
extern char unsetenv[];
extern char waitid[];
extern char waitpid[];
extern char wcrtomb[];
extern char wcscoll[];
extern char wctype[];
extern char wcwidth[];
extern char write[];
typedef struct { const char *name; void *addr; } curse_sym_t;
static const curse_sym_t curse_syms[] = {
  { "environ", (void*)&environ },
  { "__ctype_get_mb_cur_max", (void*)__ctype_get_mb_cur_max },
  { "__fpurge", (void*)__fpurge },
  { "_exit", (void*)_exit },
  { "accept", (void*)accept },
  { "access", (void*)access },
  { "bind", (void*)bind },
  { "chdir", (void*)chdir },
  { "chmod", (void*)chmod },
  { "clearenv", (void*)clearenv },
  { "clearerr", (void*)clearerr },
  { "clock_gettime", (void*)clock_gettime },
  { "close", (void*)close },
  { "closedir", (void*)closedir },
  { "confstr", (void*)confstr },
  { "curse_ldfmt", (void*)curse_ldfmt },
  { "curse_preempt_arm", (void*)curse_preempt_arm },
  { "curse_preempt_flagp", (void*)curse_preempt_flagp },
  { "curse_sig_catch", (void*)curse_sig_catch },
  { "curse_sig_clearpending", (void*)curse_sig_clearpending },
  { "curse_sig_default", (void*)curse_sig_default },
  { "curse_sig_hold", (void*)curse_sig_hold },
  { "curse_sig_ignore", (void*)curse_sig_ignore },
  { "dup", (void*)dup },
  { "dup2", (void*)dup2 },
  { "endpwent", (void*)endpwent },
  { "execve", (void*)execve },
  { "fchdir", (void*)fchdir },
  { "fchmod", (void*)fchmod },
  { "fclose", (void*)fclose },
  { "fcntl", (void*)fcntl },
  { "flock", (void*)flock },
  { "fopen", (void*)fopen },
  { "fork", (void*)fork },
  { "free", (void*)free },
  { "fstat", (void*)fstat },
  { "get_nprocs", (void*)get_nprocs },
  { "getcwd", (void*)getcwd },
  { "getegid", (void*)getegid },
  { "geteuid", (void*)geteuid },
  { "getgid", (void*)getgid },
  { "getgroups", (void*)getgroups },
  { "getpeername", (void*)getpeername },
  { "getpid", (void*)getpid },
  { "getppid", (void*)getppid },
  { "getpwent", (void*)getpwent },
  { "getpwnam", (void*)getpwnam },
  { "getpwuid", (void*)getpwuid },
  { "getrlimit", (void*)getrlimit },
  { "getrusage", (void*)getrusage },
  { "getsockopt", (void*)getsockopt },
  { "gettimeofday", (void*)gettimeofday },
  { "getuid", (void*)getuid },
  { "iconv", (void*)iconv },
  { "iconv_open", (void*)iconv_open },
  { "ioctl", (void*)ioctl },
  { "isatty", (void*)isatty },
  { "iswctype", (void*)iswctype },
  { "iswprint", (void*)iswprint },
  { "iswupper", (void*)iswupper },
  { "kill", (void*)kill },
  { "listen", (void*)listen },
  { "localeconv", (void*)localeconv },
  { "lseek", (void*)lseek },
  { "lstat", (void*)lstat },
  { "malloc", (void*)malloc },
  { "mbrtowc", (void*)mbrtowc },
  { "mkdir", (void*)mkdir },
  { "mkstemp", (void*)mkstemp },
  { "mmap", (void*)mmap },
  { "nl_langinfo", (void*)nl_langinfo },
  { "open", (void*)open },
  { "opendir", (void*)opendir },
  { "pipe", (void*)pipe },
  { "pipe2", (void*)pipe2 },
  { "poll", (void*)poll },
  { "posix_spawn", (void*)posix_spawn },
  { "posix_spawn_file_actions_addclose", (void*)posix_spawn_file_actions_addclose },
  { "posix_spawn_file_actions_adddup2", (void*)posix_spawn_file_actions_adddup2 },
  { "posix_spawn_file_actions_addopen", (void*)posix_spawn_file_actions_addopen },
  { "posix_spawn_file_actions_destroy", (void*)posix_spawn_file_actions_destroy },
  { "posix_spawn_file_actions_init", (void*)posix_spawn_file_actions_init },
  { "posix_spawnattr_destroy", (void*)posix_spawnattr_destroy },
  { "posix_spawnattr_init", (void*)posix_spawnattr_init },
  { "posix_spawnattr_setflags", (void*)posix_spawnattr_setflags },
  { "posix_spawnattr_setsigmask", (void*)posix_spawnattr_setsigmask },
  { "posix_spawnp", (void*)posix_spawnp },
  { "ppoll", (void*)ppoll },
  { "prctl", (void*)prctl },
  { "read", (void*)read },
  { "readdir", (void*)readdir },
  { "recvmsg", (void*)recvmsg },
  { "regcomp", (void*)regcomp },
  { "regexec", (void*)regexec },
  { "regfree", (void*)regfree },
  { "setenv", (void*)setenv },
  { "setlocale", (void*)setlocale },
  { "setpgid", (void*)setpgid },
  { "setpwent", (void*)setpwent },
  { "setrlimit", (void*)setrlimit },
  { "setsockopt", (void*)setsockopt },
  { "sigaction", (void*)sigaction },
  { "sigaddset", (void*)sigaddset },
  { "sigemptyset", (void*)sigemptyset },
  { "sigprocmask", (void*)sigprocmask },
  { "sigtimedwait", (void*)sigtimedwait },
  { "socket", (void*)socket },
  { "stat", (void*)stat },
  { "stdin", (void*)stdin },
  { "strcoll", (void*)strcoll },
  { "strdup", (void*)strdup },
  { "strerror", (void*)strerror },
  { "strerrordesc_np", (void*)strerrordesc_np },
  { "strtoll", (void*)strtoll },
  { "strtoull", (void*)strtoull },
  { "strxfrm", (void*)strxfrm },
  { "syscall", (void*)syscall },
  { "tee", (void*)tee },
  { "tolower", (void*)tolower },
  { "toupper", (void*)toupper },
  { "towlower", (void*)towlower },
  { "towupper", (void*)towupper },
  { "ttyname", (void*)ttyname },
  { "tzset", (void*)tzset },
  { "umask", (void*)umask },
  { "unlink", (void*)unlink },
  { "unsetenv", (void*)unsetenv },
  { "waitid", (void*)waitid },
  { "waitpid", (void*)waitpid },
  { "wcrtomb", (void*)wcrtomb },
  { "wcscoll", (void*)wcscoll },
  { "wctype", (void*)wctype },
  { "wcwidth", (void*)wcwidth },
  { "write", (void*)write },
  { 0, 0 }
};
static int streq(const char *a, const char *b){ while(*a && *a==*b){a++;b++;} return *a==*b; }
void *curse_static_sym(const char *name){
  const curse_sym_t *s; for (s = curse_syms; s->name; s++)
    if (streq(s->name, name)) return s->addr;
  return 0;
}
