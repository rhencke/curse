x=hello
if [[ $x == h* ]]; then echo "glob match"; fi
if [[ $x == "hello" ]]; then echo "literal match"; fi
if [[ $x != bye ]]; then echo "not bye"; fi
if [[ -n $x && -z "" ]]; then echo "n and z"; fi
if [[ $x == foo || $x == hello ]]; then echo "or match"; fi
if [[ ! $x == bye ]]; then echo "negated"; fi

n=42
if [[ $n -gt 10 && $n -lt 100 ]]; then echo "in range"; fi
if [[ $n -eq 42 ]]; then echo "equals 42"; fi

if [[ hello =~ ^h.*o$ ]]; then echo "regex match"; fi
if [[ abc < abd ]]; then echo "abc<abd"; fi

if [[ -f /etc/hostname || -f /nonexistent_xyz ]]; then echo "hostname exists"; fi
if [[ -d /etc ]]; then echo "/etc is dir"; fi

check() {
  if [[ "$1" == -* ]]; then
    echo "option: $1"
  elif [[ -z "$1" ]]; then
    echo "empty arg"
  else
    echo "value: $1"
  fi
}
check -v
check ""
check hello
