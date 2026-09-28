# A child shell inherits every open fd of its caller, past 63 too and however many there
# are. Through the daemon (curse-client) only fds 3-63 reached the worker: `>&70` failed
# with "Bad file descriptor" (stress-attack S8).
exec 70> f70 5> f5 200> f200 1000> f1000
$THIS_SH -c 'echo to70 >&70; echo "fd 70: $?"; echo to5 >&5; echo "fd 5: $?"; echo to200 >&200; echo "fd 200: $?"; echo to1000 >&1000; echo "fd 1000: $?"' 2>&1 | sed 's/^.*: line [0-9]*: /E: /'
exec 70>&- 5>&- 200>&- 1000>&-
echo "[$(cat f70)] [$(cat f5)] [$(cat f200)] [$(cat f1000)]"
rm -f f70 f5 f200 f1000
# 600 of them: more than one SCM_RIGHTS message carries
for ((i = 300; i < 900; i++)); do eval "exec $i> /dev/null"; done
exec 899> f899 450> f450
$THIS_SH -c 'n=0; for ((i = 300; i < 900; i++)); do { : >&$i; } 2> /dev/null && n=$((n + 1)); done; echo "open in the child: $n"; echo last >&899; echo mid >&450'
echo "[$(cat f899)] [$(cat f450)]"
f() { $THIS_SH -c 'echo "function: $(echo x >&899 && echo ok)"'; }; f
eval '$THIS_SH -c "echo eval: \$(echo y >&450 && echo ok)"'
for ((i = 300; i < 900; i++)); do eval "exec $i>&-"; done
rm -f f899 f450
( $THIS_SH -c 'echo "closed: $( { echo z >&899; } 2>&1 | sed "s/^.*: line [0-9]*: /E: /")"' )
