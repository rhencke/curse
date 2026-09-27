# SIGINT/SIGQUIT ignored in async commands (setup_async_signals) reach an external only
# when the external IS the async command (`cmd &`). Inside an async ( … ) or { … }, or a
# backgrounded function, the external's child restores the original dispositions
# (execute_disk_command: restore_original_signals, setup_async_signals only if async
# itself): its SigIgn is clear. Also in a hot loop (compiled).
ign() { sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status; }
( sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status ) & wait
( sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status; true ) & wait
{ sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status; } & wait
sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status & wait
ign & wait
n=0
for ((i = 0; i < 150; i++)); do
	x=$( ( sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status ) & wait )
	[ "$x" = 0000000000000000 ] && n=$((n+1))
done
echo "hot: $n"
