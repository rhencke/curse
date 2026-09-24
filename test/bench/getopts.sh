p() { local OPTIND=1 o a=0; while getopts "ab:c" o "$@"; do case $o in a) a=$((a+1));; esac; done; r=$a; }; for ((i=0;i<5000;i++)); do p -a -b x -c -a; done; echo $r
