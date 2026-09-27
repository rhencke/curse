#!/bin/sh
# Extract an AFL dictionary from the bash 5.2.21 sources: parse.y's reserved words and
# operator tokens, every builtin's name (builtins/*.def $BUILTIN lines), the shopt and
# `set -o` option names. Complements the hand-written tools/fuzz/sh.dict.
#   mkdict.sh BASH_SRC_DIR > auto.dict
set -eu
B=$1
{
  # reserved words + multi-char tokens: { "word", TOKEN } in word_token_alist / other_token_alist
  sed -n '/^STRING_INT_ALIST word_token_alist/,/^};/p; /^STRING_INT_ALIST other_token_alist/,/^};/p' "$B/parse.y" |
    sed -n 's/^ *{ "\([^"]*\)",.*/\1/p'
  sed -n 's/^\$BUILTIN[ \t]*\([^ \t]*\).*/\1/p' "$B"/builtins/*.def
  # shopt options: { "name", &var, ... } in shopt.def's shopt_vars
  sed -n '/^static struct {/,/^};/p' "$B/builtins/shopt.def" | sed -n 's/^ *{ "\([a-z_0-9]*\)",.*/\1/p'
  # set -o options: o_options in builtins/set.def
  sed -n '/^const struct {/,/^};/p' "$B/builtins/set.def" | sed -n 's/^ *{ "\([a-z_0-9-]*\)",.*/\1/p'
} | LC_ALL=C sort -u | awk 'length($0) > 0 && !/[\\"]/ { printf "b%d=\"%s\"\n", NR, $0 }'
