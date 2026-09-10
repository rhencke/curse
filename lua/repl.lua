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
local interactive = ffi.C.isatty(0) == 1

-- One line of input. With readline: full editing + history. Otherwise plain read.
local function read_line(prompt)
  if RL then
    local c = RL.readline(prompt)
    if c == nil then return nil end -- EOF (Ctrl-D)
    local s = ffi.string(c); ffi.C.free(c)
    return s
  end
  if interactive then io.write(prompt); io.flush() end
  return io.read("*l")
end

-- Heuristic: does `buf` have an obviously-unterminated construct, so the REPL
-- should keep reading (PS2) instead of trying to run it? Counts unbalanced quotes,
-- $(/${/(( , a trailing backslash, and open block keywords vs their closers.
local function needs_more(buf)
  if buf:sub(-1) == "\\" then return true end
  local i, n = 1, #buf
  local sq, dq, paren, brace = false, false, 0, 0 -- paren counts ( $( $(( uniformly
  local words = {}
  while i <= n do
    local c = buf:sub(i, i)
    if sq then if c == "'" then sq = false end; i = i + 1
    elseif dq then
      if c == "\\" then i = i + 2 elseif c == '"' then dq = false; i = i + 1 else i = i + 1 end
    elseif c == "'" then sq = true; i = i + 1
    elseif c == '"' then dq = true; i = i + 1
    elseif c == "\\" then i = i + 2
    elseif c == "#" then while i <= n and buf:sub(i, i) ~= "\n" do i = i + 1 end
    elseif c == "$" and buf:sub(i + 1, i + 2) == "((" then paren = paren + 2; i = i + 3
    elseif c == "$" and buf:sub(i + 1, i + 1) == "(" then paren = paren + 1; i = i + 2
    elseif c == "$" and buf:sub(i + 1, i + 1) == "{" then brace = brace + 1; i = i + 2
    elseif c == "(" then paren = paren + 1; i = i + 1
    elseif c == ")" then paren = paren - 1; i = i + 1
    elseif c == "}" then brace = brace - 1; i = i + 1
    else
      local s, e, w = buf:find("^([%a_][%w_]*)", i)
      if w then words[#words + 1] = w; i = e + 1 else i = i + 1 end
    end
  end
  if sq or dq or paren > 0 or brace > 0 then return true end
  -- block keywords: opens (if/for/while/until/case/select) must be closed
  local opens, closes = 0, 0
  for _, w in ipairs(words) do
    if w == "if" or w == "for" or w == "while" or w == "until" or w == "case" or w == "select" then opens = opens + 1
    elseif w == "fi" or w == "done" or w == "esac" then closes = closes + 1 end
  end
  return opens > closes
end

-- Expand PS1/PS2 escapes for the prompt via the shared, full prompt decoder.
local function prompt_of(sh, var, default)
  return sh:prompt_escapes(sh.vars[var] and sh:get(var) or default)
end

local M = {}
function M.run(sh)
  if RL then
    RL.using_history()
    local hist = os.getenv("HISTFILE") or ((os.getenv("HOME") or ".") .. "/.curse_history")
    pcall(function() RL.read_history(hist) end)
  end
  local buf = ""
  while true do
    local prompt = buf == "" and prompt_of(sh, "PS1", "curse\\$ ") or prompt_of(sh, "PS2", "> ")
    local line = read_line(prompt)
    if line == nil then -- EOF
      if interactive then io.write("\n") end
      break
    end
    buf = (buf == "") and line or (buf .. "\n" .. line)
    if buf:match("%S") and needs_more(buf) then
      -- keep reading this logical command on the next line (PS2)
    else
      if buf:match("%S") then
        if RL then RL.add_history(buf) end
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
  if RL then
    local hist = os.getenv("HISTFILE") or ((os.getenv("HOME") or ".") .. "/.curse_history")
    pcall(function() RL.write_history(hist) end)
  end
end

return M
