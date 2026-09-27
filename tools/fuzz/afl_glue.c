/* AFL map access, compiled WITHOUT afl-cc (the pass owns these names in an
 * instrumented TU). Weak: the plain (uninstrumented) harness links with no AFL runtime. */
extern unsigned char *__afl_area_ptr __attribute__((weak));
extern unsigned int __afl_map_size __attribute__((weak));
unsigned char *fuzz_area(void) { return &__afl_area_ptr ? __afl_area_ptr : 0; }
unsigned int fuzz_map_size(void) { return &__afl_map_size ? __afl_map_size : 0; }
/* The pcguard runtime reports __afl_final_loc (its ~130 C edges) as the map size at the
 * forkserver handshake, so afl-fuzz would only ever read the first ~130 bytes. The Lua
 * edges need the whole map: claim it before __AFL_INIT (deferred init reads it then). */
extern unsigned int __afl_final_loc __attribute__((weak));
void fuzz_claim_map(unsigned int n) { if (&__afl_final_loc) __afl_final_loc = n; if (&__afl_map_size) __afl_map_size = n; }
