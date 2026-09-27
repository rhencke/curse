# `exec 1>&-` (a static or a dynamic `exec` name) inside a pipeline stage: its fd-1
# routing persists like its redirections, so a later builtin's write error is reported.
e=exec
( exec 1>&-; echo x ) 2>&1 | sed 's/^.*line [0-9]*: //'
( $e 1>&-; echo y ) 2>&1 | sed 's/^.*line [0-9]*: //'
( command exec 1>&-; echo z ) 2>&1 | sed 's/^.*line [0-9]*: //'
