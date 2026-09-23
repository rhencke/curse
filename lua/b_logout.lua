-- Lazily-loaded `logout` builtin (see BUILTIN_LAZY in interp.lua): exit, but only from a
-- login shell (curse never is one).
return function(sh, cmd, args)
	if not sh.login_shell then
		io.stderr:write("curse: logout: not login shell: use `exit'\n")
		sh.status = 1
		return
	end
	error({ __curse_exit = tonumber(args[2]) or sh.status })
end
