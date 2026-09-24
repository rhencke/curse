s="the quick brown fox jumps over the lazy dog"; for ((i=0;i<20000;i++)); do t=${s//o/0}; u=${t%% *}; v=${s#* }; done; echo "$t $u"
