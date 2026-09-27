# A function's <(…)/>(…) are closed when it returns (bash's execute_function:
# close_new_fifos / unlink_fifo_list), and a statement's when a break/continue jumps
# out of it — also from a compiled (hot) function or loop, where the jump skips the
# statement's own drain. Counted as the fds a child inherits.
n() { ls /proc/self/fd | wc -l; }
a=$(n)
f() { while read -r l; do return 3; done < <(printf 'a\nb\n'); }
for ((k = 0; k < 200; k++)); do f; done
echo "return: $? $(($(n) - a))"
g() { for i in 1; do while read -r l; do break 2; done < <(printf 'a\nb\n'); done; }
for ((k = 0; k < 200; k++)); do g; done
echo "break 2: $(($(n) - a))"
h() { { read -r l; return 4; } < <(printf 'a\n'); }
for ((k = 0; k < 200; k++)); do h; done
echo "group: $? $(($(n) - a))"
for ((k = 0; k < 200; k++)); do for i in 1; do while read -r l; do continue 2; done < <(printf 'a\n'); done; done
echo "top continue 2: $(($(n) - a))"
j() { while read -r l; do while read -r m; do return 5; done < <(printf 'c\n'); done < <(printf 'a\n'); }
for ((k = 0; k < 200; k++)); do j; done
echo "nested: $? $(($(n) - a))"
w() { while read -r l; do eval 'return 6'; done < <(printf 'a\n'); }
for ((k = 0; k < 200; k++)); do w; done
echo "eval return: $? $(($(n) - a))"
x() { for i in 1 2; do { while read -r l; do break 2; done; } < <(printf 'a\n'); done; }
for ((k = 0; k < 200; k++)); do x; done
echo "break from a group: $(($(n) - a))"
