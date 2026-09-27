# bash undefined behaviour: documented, not mimicked

curse is bug-for-bug compatible with bash 5.2.21: every *defined* bash behaviour, bugs
included, is reproduced (the conformance oracle is the in-tree 5.2.21 build). The one
exception is behaviour that exists only because bash hits C **undefined behaviour**
(out-of-bounds or uninitialized reads, overflows, bad pointers). Its outcome depends on
heap/stack contents, so bash itself varies between runs, builds and contexts; copying
it would mean shipping UB (and possible security holes). For each such case curse picks
one sane, deterministic behaviour, documented here and pinned by `test/ub/`.

How a case qualifies: the bash source shows the UB, and the pinned oracle's output is
not stable across runs or contexts. A merely *odd* but deterministic bash behaviour is
a quirk and must be copied — it doesn't belong here.

| Case | bash 5.2.21 source | Why it is UB | curse's choice | Pinned by |
|---|---|---|---|---|
| `jobs %spec` where the spec is ambiguous (e.g. `%sleep` with two sleep jobs) | builtins/jobs.def `jobs_builtin`: `get_job_spec` returns `DUP_JOB` (-2); `get_job_by_jid(job) == 0` with `#define get_job_by_jid(ind) (jobs[(ind)])` (jobs.h:91) | reads `jobs[-2]`, the word before the job array (glibc: the previous heap chunk's tail), so "no such job" + status 1 appear only when that word happens to be 0. It depends on the heap history, not on the syntactic context: probed on the pinned 5.2.21, a three-line script gives status 1 at top level, in a function and in a loop (test/ub/jobs-dupjob-small.sh), while test/ub/jobs-dupjob.sh and test/cases/1820 (top level and from a function) give status 0 every run | the outcome bash gives in real scripts with some heap history: only "ambiguous job spec", status 0, in every context — so 1820's `j jobs %sleep` matches the oracle deterministically. (`kill`/`wait`/`disown`/`fg`/`bg` check `INVALID_JOB()` or `j < 0` first — deterministic, copied exactly; see test/cases/2525) | test/ub/jobs-dupjob.sh, test/ub/jobs-dupjob-small.sh (where bash gives 1), test/cases/1820 (where bash gives 0) |
| Word splitting when IFS is not valid text in the locale and a pending `mbtowc` character completes on the unquoted IFS[0] between quoted elements | subst.c `string_extract_verbatim` / `list_string`: `wcschr(wcharlist, wc)` | `mbstowcs` failed, leaving `wcharlist` uninitialized heap memory | IFS taken as holding nothing (the elements are joined by IFS[0], not split) | test/ub/ifs-mb-wcharlist.sh (lua/runtime.lua FB:multi) |
| IFS whose first character is longer than the current `MB_CUR_MAX` (IFS set under a UTF-8 locale, then `LC_ALL=C`) | subst.c: `char sep[MB_CUR_MAX+1]` filled from `ifs_firstc` | stack buffer overflow | the first character is used whole (`"$*"` joins with all its bytes) | test/ub/ifs-sep-overflow.sh |
