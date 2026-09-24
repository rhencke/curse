n=0; for ((i=0;i<30000;i++)); do case "item$((i%5))" in item0) n=$((n+1));; item[12]) :;; *3) :;; *) :;; esac; done; echo $n
