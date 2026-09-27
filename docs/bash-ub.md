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
| `jobs %spec` where the spec is ambiguous (e.g. `%sleep` with two sleep jobs) | builtins/jobs.def `jobs_builtin`: `get_job_spec` returns `DUP_JOB` (-2); `get_job_by_jid(job) == 0` with `#define get_job_by_jid(ind) (jobs[(ind)])` (jobs.h:91) | reads `jobs[-2]`, before the job array: "no such job" + status 1 appear only when that word happens to be 0 (observed: 1 at the top of a script, 0 inside a loop) | bash's common case (the word is a non-zero malloc header): only "ambiguous job spec", status 0. (`kill`/`wait`/`disown`/`fg`/`bg` check `INVALID_JOB()` or `j < 0` first — deterministic, copied exactly; see test/cases/2525) | test/ub/jobs-dupjob.sh |
| Word splitting when IFS is not valid text in the locale and a pending `mbtowc` character completes on the unquoted IFS[0] between quoted elements | subst.c `string_extract_verbatim` / `list_string`: `wcschr(wcharlist, wc)` | `mbstowcs` failed, leaving `wcharlist` uninitialized heap memory | IFS taken as holding nothing (the element is joined, not split) | lua/runtime.lua FB:multi comment; pin TODO |
| IFS whose first character is longer than the current `MB_CUR_MAX` (IFS set under a UTF-8 locale, then `LC_ALL=C`) | subst.c: `char sep[MB_CUR_MAX+1]` filled from `ifs_firstc` | stack buffer overflow | the first character is used whole | pin TODO |
