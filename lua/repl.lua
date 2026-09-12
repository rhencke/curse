-- Interactive REPL. Uses GNU readline (the same library bash links) via FFI for
-- line editing, history, and completion — no need to reimplement any of it. Falls
-- back to plain line reading when readline or a tty isn't available.
local ffi = require("ffi")
local parser = require("parser")
local interp = require("interp")

ffi.cdef [[
  char *readline(const char *prompt);
  void add_history(const char *line);
  int read_history(const char *filename);
  int write_history(const char *filename);
  void using_history(void);
  int isatty(int fd);
  void free(void *ptr);
]]

-- Try to load readline by the names it ships under (there's often no unversioned
-- libreadline.so symlink, so probe the versioned soname too).
local RL
for _, name in ipairs({ "readline", "libreadline.so.8", "libreadline.so.7", "libreadline.so" }) do
  local ok, lib = pcall(ffi.load, name)
  if ok then RL = lib; break end
end
local istty = ffi.C.isatty(0) == 1
local interactive = istty -- becomes true for `-i` too once run() sees opt_i

-- One line of input. With readline: full editing + history. Otherwise plain read.
local function read_line(prompt)
  if RL and istty then -- readline only on a real tty; piped stdin prompts to stderr
    local c = RL.readline(prompt)
    if c == nil then return nil end -- EOF (Ctrl-D)
    local s = ffi.string(c); ffi.C.free(c)
    return s
  end
  -- The prompt goes to STDERR (bash), so a script's captured stdout isn't polluted
  -- by PS1/PS2 when commands are piped into an interactive shell.
  if interactive then io.stderr:write(prompt) end
  return io.read("*l")
end

-- Does `buf` have an obviously-unterminated construct, so the REPL should keep
-- reading (PS2) instead of running it? Shared with interp.source_file (rc-file
-- completeness). See interp.incomplete_input.
local needs_more = interp.incomplete_input

-- Expand PS1/PS2 escapes for the prompt via the shared, full prompt decoder.
local function prompt_of(sh, var, default)
  return sh:prompt_escapes(sh.vars[var] and sh:get(var) or default)
end

local M = {}
function M.run(sh)
  interactive = istty or (sh and sh.opt_i) or false -- prompts print for `-i` even off a tty
  -- Persist $HISTFILE across the session (load now, write at exit) — but only when
  -- it was EXPLICITLY set (env/script), never the ~/.bash_history default, so a
  -- piped `-i` run never clobbers the user's real history. On a real tty, readline
  -- also loads its editing history from the same file.
  local histfile = sh:get("HISTFILE")
  if histfile == "" or sh.histfile_default then histfile = nil end
  if histfile then
    sh.history = sh.history or {}
    local f = io.open(histfile, "r")
    if f then for line in f:lines() do sh.history[#sh.history + 1] = line end; f:close() end
  end
  if RL and istty then
    RL.using_history()
    pcall(function() RL.read_history(histfile or os.getenv("HISTFILE") or ((os.getenv("HOME") or ".") .. "/.curse_history")) end)
  end
  local buf = ""
  while true do
    if buf == "" then -- before each PRIMARY prompt, bash runs $PROMPT_COMMAND
      local ok, err = pcall(interp.run_prompt_command, sh)
      if not ok and type(err) == "table" and err.__curse_exit then io.flush(); break end
      io.flush()
    end
    local prompt = buf == "" and prompt_of(sh, "PS1", "curse\\$ ") or prompt_of(sh, "PS2", "> ")
    local line = read_line(prompt)
    if line == nil then -- EOF
      if interactive then io.stderr:write("\n") end -- final newline to stderr, like the prompt
      break
    end
    buf = (buf == "") and line or (buf .. "\n" .. line)
    if buf:match("%S") and needs_more(buf) then
      -- keep reading this logical command on the next line (PS2)
    else
      if buf:match("%S") then
        if sh.opt_history ~= false then -- `set +o history` stops recording (bash), not execution
          sh.history = sh.history or {}; sh.history[#sh.history + 1] = buf -- for `history`/`fc`
          local hsz = tonumber(sh:get("HISTSIZE")) -- bash trims to HISTSIZE on each add
          if hsz and hsz >= 0 then while #sh.history > hsz do table.remove(sh.history, 1) end end
          if RL and istty then RL.add_history(buf) end
        end
        local ok, err = pcall(interp.run_lazy, sh, buf)
        if not ok and type(err) == "table" and err.__curse_exit then
          io.flush(); break -- `exit` in the REPL
        elseif not ok then
          io.stderr:write("curse: " .. tostring(type(err) == "table" and "error" or err) .. "\n")
        end
        io.flush()
      end
      buf = ""
    end
  end
  if histfile then -- write the session's history back to an explicit $HISTFILE
    -- `shopt -s histappend` appends the session's list to the file; otherwise it
    -- overwrites (bash). (HISTSIZE has already trimmed the in-memory list.)
    local f = io.open(histfile, (sh.shopt and sh.shopt.histappend) and "a" or "w")
    if f then for _, h in ipairs(sh.history or {}) do f:write(h, "\n") end; f:close() end
  elseif RL and istty then
    pcall(function() RL.write_history((os.getenv("HOME") or ".") .. "/.curse_history") end)
  end
end

return M
