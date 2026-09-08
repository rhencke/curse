if ! false; then echo "not false"; fi
! true
echo "after ! true: $?"
! false
echo "after ! false: $?"
if ! [ -f /nonexistent_file_xyz ]; then echo "no such file"; fi
