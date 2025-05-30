-- adopted from neovim/nvim-lspconfig, see lspconfig.LICENSE.md

local vim = vim
local validate = vim.validate
local api = vim.api
local lsp = vim.lsp
local uv = vim.loop
local fn = vim.fn

local M = {}

local flatten = (function()
  if vim.fn.has "nvim-0.11" == 1 then
    return function(t)
      return vim.iter(t):flatten():totable()
    end
  else
    return function(t)
      return vim.tbl_flatten(t)
    end
  end
end)()

M.default_config = {
  log_level = lsp.protocol.MessageType.Warning,
  message_level = lsp.protocol.MessageType.Warning,
  settings = vim.empty_dict(),
  init_options = vim.empty_dict(),
  handlers = {},
}

function M.validate_bufnr(bufnr)
  validate {
    bufnr = { bufnr, "n" },
  }
  return bufnr == 0 and api.nvim_get_current_buf() or bufnr
end

function M.add_hook_before(func, new_fn)
  if func then
    return function(...)
      -- TODO which result?
      new_fn(...)
      return func(...)
    end
  else
    return new_fn
  end
end

function M.add_hook_after(func, new_fn)
  if func then
    return function(...)
      -- TODO which result?
      func(...)
      return new_fn(...)
    end
  else
    return new_fn
  end
end

function M.create_module_commands(module_name, commands)
  for command_name, def in pairs(commands) do
    local parts = { "command!" }
    -- Insert attributes.
    for k, v in pairs(def) do
      if type(k) == "string" and type(v) == "boolean" and v then
        table.insert(parts, "-" .. k)
      elseif type(k) == "number" and type(v) == "string" and v:match "^%-" then
        table.insert(parts, v)
      end
    end
    table.insert(parts, command_name)
    -- The command definition.
    table.insert(
      parts,
      string.format("lua require'lspconfig'[%q].commands[%q][1](<f-args>)", module_name, command_name)
    )
    api.nvim_command(table.concat(parts, " "))
  end
end

function M.has_bins(...)
  for i = 1, select("#", ...) do
    if 0 == fn.executable((select(i, ...))) then
      return false
    end
  end
  return true
end

M.script_path = function()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match "(.*[/\\])"
end

-- Some path utilities
M.path = (function()
  local function exists(filename)
    local stat = uv.fs_stat(filename)
    return stat and stat.type or false
  end

  local function is_dir(filename)
    return exists(filename) == "directory"
  end

  local function is_file(filename)
    return exists(filename) == "file"
  end

  local is_windows = uv.os_uname().version:match "Windows"
  local path_sep = is_windows and "\\" or "/"

  local is_fs_root
  if is_windows then
    is_fs_root = function(path)
      return path:match "^%a:$"
    end
  else
    is_fs_root = function(path)
      return path == "/"
    end
  end

  local function is_absolute(filename)
    if is_windows then
      return filename:match "^%a:" or filename:match "^\\\\"
    else
      return filename:match "^/"
    end
  end

  local dirname
  do
    local strip_dir_pat = path_sep .. "([^" .. path_sep .. "]+)$"
    local strip_sep_pat = path_sep .. "$"
    dirname = function(path)
      if not path or #path == 0 then
        return
      end
      local result = path:gsub(strip_sep_pat, ""):gsub(strip_dir_pat, "")
      if #result == 0 then
        return "/"
      end
      return result
    end
  end

  local function path_join(...)
    local result = table.concat(flatten { ... }, path_sep):gsub(path_sep .. "+", path_sep)
    return result
  end

  -- Traverse the path calling cb along the way.
  local function traverse_parents(path, cb)
    path = uv.fs_realpath(path)
    local dir = path
    -- Just in case our algo is buggy, don't infinite loop.
    for _ = 1, 100 do
      dir = dirname(dir)
      if not dir then
        return
      end
      -- If we can't ascend further, then stop looking.
      if cb(dir, path) then
        return dir, path
      end
      if is_fs_root(dir) then
        break
      end
    end
  end

  -- Iterate the path until we find the rootdir.
  local function iterate_parents(path)
    path = uv.fs_realpath(path) or path
    local function it(s, v)
      if not v then
        return
      end
      if is_fs_root(v) then
        return
      end
      return dirname(v), path
    end
    return it, path, path
  end

  local function is_descendant(root, path)
    if not path then
      return false
    end

    local function cb(dir, _)
      return dir == root
    end

    local dir, _ = traverse_parents(path, cb)

    return dir == root
  end

  return {
    is_dir = is_dir,
    is_file = is_file,
    is_absolute = is_absolute,
    exists = exists,
    sep = path_sep,
    dirname = dirname,
    join = path_join,
    traverse_parents = traverse_parents,
    iterate_parents = iterate_parents,
    is_descendant = is_descendant,
  }
end)()

-- Returns a function(root_dir), which, when called with a root_dir it hasn't
-- seen before, will call make_config(root_dir) and start a new client.
function M.server_per_root_dir_manager(_make_config)
  local clients = {}
  local manager = {}

  function manager.add(root_dir)
    if not root_dir then
      return
    end
    if not M.path.is_dir(root_dir) then
      return
    end

    -- Check if we have a client alredy or start and store it.
    local client_id = clients[root_dir]
    if not client_id then
      local new_config = _make_config(root_dir)
      --TODO:mjlbach -- these prints only show up with nvim_error_writeln()
      if not new_config.cmd then
        print(
          string.format(
            "Error, cmd not defined for [%q]."
              .. "You must manually define a cmd for the default config for this server."
              .. "See server documentation.",
            new_config.name
          )
        )
        return
      elseif vim.fn.executable(new_config.cmd[1]) == 0 then
        vim.notify(string.format("cmd [%q] is not executable.", new_config.cmd[1]), vim.log.levels.Error)
        return
      end
      new_config.on_exit = M.add_hook_before(new_config.on_exit, function()
        clients[root_dir] = nil
      end)
      client_id = lsp.start_client(new_config)
      clients[root_dir] = client_id
    end
    return client_id
  end

  function manager.clients()
    local res = {}
    for _, id in pairs(clients) do
      local client = lsp.get_client_by_id(id)
      if client then
        table.insert(res, client)
      end
    end
    return res
  end

  return manager
end

function M.search_ancestors(startpath, func)
  validate { func = { func, "f" } }
  if func(startpath) then
    return startpath
  end
  for path in M.path.iterate_parents(startpath) do
    if func(path) then
      return path
    end
  end
end

function M.root_pattern(...)
  local patterns = flatten { ... }
  local function matcher(path)
    for _, pattern in ipairs(patterns) do
      for _, p in ipairs(vim.fn.glob(M.path.join(path, pattern), true, true)) do
        if M.path.exists(p) then
          return path
        end
      end
    end
  end
  return function(startpath)
    return M.search_ancestors(startpath, matcher)
  end
end
function M.find_git_ancestor(startpath)
  return M.search_ancestors(startpath, function(path)
    if M.path.is_dir(M.path.join(path, ".git")) then
      return path
    end
  end)
end
function M.find_node_modules_ancestor(startpath)
  return M.search_ancestors(startpath, function(path)
    if M.path.is_dir(M.path.join(path, "node_modules")) then
      return path
    end
  end)
end
function M.find_package_json_ancestor(startpath)
  return M.search_ancestors(startpath, function(path)
    if M.path.is_file(M.path.join(path, "package.json")) then
      return path
    end
  end)
end

return M
-- vim:et ts=2 sw=2
