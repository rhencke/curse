cat <<EOF
plain line
another line
EOF

name=world
cat <<EOF
hello $name
sum is $((2 + 3))
sub: $(echo nested)
EOF

# quoted delimiter -> no expansion
cat <<'EOF'
literal $name and $((1+1))
EOF

# <<- strips leading tabs
cat <<-END
	indented with tab
	another
	END

# heredoc feeding a filter
tr a-z A-Z <<EOF
shout this
EOF

# heredoc into read (via a pipe would subshell; use redirect on a group)
total=0
while read n; do
  total=$((total + n))
done <<EOF
10
20
30
EOF
echo "total=$total"
