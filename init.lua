local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Object = require "core.object"


-- CONSTANTS
local PLUGIN_PATH = system.absolute_path(EXEDIR .. "/data/plugins")
local PLUGIN_URL = "https://raw.githubusercontent.com/rxi/lite-plugins/master/README.md"


local ListView = View:extend()

function ListView:new(data)
  ListView.super.new(self)
  self.data = data
  self.selected = 1
  self.scrollable = true
end

function ListView:get_line_height()
  return style.code_font:get_height() + style.font:get_height() + 3 * style.padding.y
end

function ListView:get_name()
  return "List"
end

function ListView:get_scrollable_size()
  return #self.data * self:get_line_height()
end

function ListView:get_visible_line_range()
  local lh = self:get_line_height()
  local min = math.max(1, math.floor(self.scroll.y / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end

function ListView:each_visible_item()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_line_range()
    y = y + lh * (min - 1) + style.padding.y
    max = math.min(max, #self.data)

    for i = min, max do
      local item = self.data[i]
      if not item then break end
      coroutine.yield(i, item, x, y, self.size.x, lh)
      y = y + lh
    end
  end)
end

function ListView:scroll_to_line(i)
  local min, max = self:get_visible_line_range()
  if i > min and i <= max then
    local lh = self:get_line_height()
    self.scroll.to.y = math.max(0, lh * (i - 1) - self.size.y / 2)
    self.scroll.y = self.scroll.to.y
  end
end

function ListView:on_mouse_moved(mx, my, ...)
  ListView.super.on_mouse_moved(self, mx, my, ...)
  for i, _, x, y, w, h in self:each_visible_item() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.selected = i
    end
  end
end

function ListView:on_mouse_pressed(button)
  if self.selected and self.on_selected then
    self:on_selected(self.data[self.selected], button)
  end
end

function ListView:on_selected()
  -- no op for extension
end

local function approx_slice(desired, font, text)
  local est = math.floor(desired / font:get_width(text:sub(1, 1)))
  local s, w
  for i = est, 0, -1 do
    s = text:sub(1, i)
    w = font:get_width(s)
    if w <= desired then
      return s, w
    end
  end
end

function ListView:draw()
  self:draw_background(style.background)

  local lh1, lh2 = style.code_font:get_height(), style.font:get_height()
  for i, item, x, y, w, h in self:each_visible_item() do
    local tx = x + style.padding.x
    local text, tw = approx_slice(w, style.code_font, item.text)
    local subtext, stw = approx_slice(w, style.font, item.subtext)

    if i == self.selected then
      renderer.draw_rect(x, y, self.size.x, h, style.accent)
    end

    y = y + style.padding.y
    common.draw_text(style.code_font, style.text, text, "left", tx, y, tw, lh1)
    y = y + lh1 + style.padding.y
    common.draw_text(style.font, style.dim, subtext, "left", tx, y, stw, lh2)
  end

  self:draw_scrollbar()
end

command.add(ListView, {
  ["list:previous-entry"] = function()
    local v = core.active_view
    v.selected = common.clamp(v.selected - 1, 1, #v.data)
    v:scroll_to_line(v.selected)
  end,
  ["list:next-entry"] = function()
    local v = core.active_view
    v.selected = common.clamp(v.selected + 1, 1, #v.data)
    v:scroll_to_line(v.selected)
  end,
  ["list:select-entry"] = function()
    local v = core.active_view
    v:on_selected(v.data[v.selected], "left")
  end,
  ["list:close"] = function()
    command.perform "root:close"
  end,
  ["list:find"] = function()
    local v = core.active_view
    local data = {}
    for i, entry in ipairs(v.data) do data[i] = entry.text end
    core.command_view:enter("Find", nil, function(needle)
      local res = common.fuzzy_match(data, needle)
      core.status_view:show_message("i", style.text, #res.." results found")
      for i, entry in ipairs(res) do res[entry] = i; res[i] = nil end
      table.sort(v.data, function (a, b) return (res[a.text] or 0) > (res[b.text] or 0) end)
     -- return {}
    end)
  end
})

keymap.add {
  ["up"]    = "list:previous-entry",
  ["down"]  = "list:next-entry",
  ["return"] = "list:select-entry",
  ["keypad enter"] = "list:select-entry",
  ["escape"] = "list:close",
  ["ctrl+f"] = "list:find"
}


local function await(fn, ...)
  local args = {...}
  local res
  table.insert(args, function(...) res = {...} end)
  fn(table.unpack(args))
  while true do
    coroutine.yield(0.1)
    if res then
      return table.unpack(res)
    end
  end
end

local function await_all(fn, ...)
  local YIELD_PARENT = {}
  local args = {...}
  local res
  table.insert(args, function(...) res = {...} end)
  fn(table.unpack(args))
  local co = coroutine.create(function()
    while true do
      if res then
        coroutine.yield(table.unpack(res))
        res = nil
      else
        coroutine.yield(YIELD_PARENT)
      end
    end
  end)

  return function()
    while true do
      coroutine.yield(0.1)
      local r = table.pack(coroutine.resume(co))
      if not r[1] then return end
      if r[2] ~= YIELD_PARENT then return table.unpack(r, 2) end
    end
  end
end

local function read_file(filename)
  local f, e = io.open(filename, "r")
  if not f then return nil, e end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(filename, content)
  local f, e = io.open(filename, "w")
  if not f then return nil, e end
  f:write(content)
  f:close()
  return true
end

local Cmd = Object:extend()

function Cmd:new(scan_interval)
  scan_interval = scan_interval or 0.1
  self.q = {}

  core.add_thread(function()
    while true do
      coroutine.yield(scan_interval)
      local n, j = #self.q, 1

      for _, v in ipairs(self.q) do
        if not self:dispatch(v) then
          self.q[j] = v
          j = j + 1
        end
      end
      for i = j, n do self.q[i] = nil end
    end
  end)
end

function Cmd:dispatch(item)
  if system.get_time() > item.timeout then
    item.callback(nil, "Timeout reached")
    return true
  end

  -- check completion files
  local completion = read_file(item.completion)
  if completion then
    local content, err = read_file(item.output)
    if content then
      os.remove(item.script)
      os.remove(item.output)
      os.remove(item.completion)
      if item.script2 then os.remove(item.script2) end
      item.callback(content, tonumber(completion))
    else
      item.callback(nil, err)
    end
    return true
  end

  return false
end

function Cmd:run(cmd, timeout, callback)
  if type(timeout) == "function" and callback == nil then
    callback = timeout
    timeout = 10
  end
  local script = core.temp_filename(PLATFORM == "Windows" and ".bat")
  local script2 = core.temp_filename(PLATFORM == "Windows" and ".bat")
  local output = core.temp_filename()
  local completion = core.temp_filename()

  if PLATFORM == "Windows" then
    write_file(script, cmd .. "\n")
    write_file(script2, string.format([[
      @echo off
      call %q > %q 2>&1
      echo %%errorLevel%% > %q
      exit
    ]], script, output, completion))
    system.exec(string.format("call %q", script2))
  else
    write_file(script, string.format([[
      %s
      echo $? > %q
      exit
    ]], cmd, completion))
    system.exec(string.format("sh %q > %q 2>&1", script, output))
  end

  table.insert(self.q, {
    script = script,
    script2 = PLATFORM == "Windows" and script2,
    output = output,
    completion = completion,
    timeout = system.get_time() + timeout,
    callback = callback
  })
end


local cmd_queue = Cmd()

local function run_async(cmd)
  return await(cmd_queue.run, cmd_queue, cmd)
end

local function first_line(str)
  return str:match("(.*)\r?\n?")
end

local function process_error(content, exit)
  if exit == 0 then
    return content
  else
    return nil, first_line(content)
  end
end

local function scandir(root, maxlevel)
  maxlevel = maxlevel or 10
  local function scandir_worker(dir, level)
    local d = system.list_dir(dir)
    for _, name in ipairs(d) do
      if not common.match_pattern(name, config.ignore_files) then
        name = dir .. PATHSEP .. name
        local stat = system.get_file_info(name)
        coroutine.yield(name, stat)
        if stat.type == "dir" then
          if level >= maxlevel then return end
          scandir_worker(name, level + 1)
        end
      end
    end
  end
  return coroutine.wrap(scandir_worker), root, 1
end

local function rmr(dir)
  local content, exit
  if PLATFORM == "Windows" then
    content, exit = run_async(string.format("DEL /F /S /Q %q", dir))
  else
    content, exit = run_async(string.format("rm -rf %q", dir))
  end
  return process_error(content, exit)
end

local function mkdirp(dir)
  local content, exit
  if PLATFORM == "Windows" then
    content, exit = run_async(string.format([[
      @echo off
      setlocal enableextensions
      mkdir %q
      endlocal
    ]], dir))
  else
    content, exit = run_async(string.format("mkdir -p %q", dir))
  end
  return process_error(content, exit)
end

local curl = { name = "curl" }
function curl.runnable()
  local _, exit = run_async "curl --version"
  return exit == 0
end
function curl.get(url)
  local content, exit = run_async(string.format("curl -fsSL %q", url))
  return process_error(content, exit)
end
function curl.download_file(url, filename)
  local content, exit = run_async(string.format("curl -o %q -fsSL %q", filename, url))
  return process_error(content, exit)
end

local wget = { name = "wget" }
function wget.runnable()
  local _, exit = run_async "wget --version"
  return exit == 0
end
function wget.get(url)
  local content, exit = run_async(string.format("wget -qO- %q", url))
  return process_error(content, exit)
end
function wget.download_file(url, filename)
  local content, exit = run_async(string.format("wget -qO %q %q", filename, url))
  return process_error(content, exit)
end

local powershell = { name = "powershell" }
function powershell.runnable()
  local _, exit = run_async "powershell -Version"
  return exit == 0
end
function powershell.get(url)
  local content, exit = run_async(string.format([[
    echo Invoke-WebRequest -UseBasicParsing -Uri %q ^| Select-Object -ExpandProperty Content ^
    | powershell -NoProfile -NonInteractive -NoLogo -Command -
  ]], url))
  return process_error(content, exit)
end
function powershell.download_file(url, filename)
  local content, exit = run_async(string.format([[
    echo Invoke-WebRequest -UseBasicParsing -outputFile %q -Uri %q ^
    | powershell -NoProfile -NonInteractive -NoLogo -Command -
  ]], filename, url))
  return process_error(content, exit)
end

local git = { name = "git" }
function git.runnable()
  local _, exit = run_async "git --version"
  return exit == 0
end
function git.clone(url, path)
  local content, exit = run_async(string.format("git clone -q %q %q", url, path))
  if exit ~= 0 then return process_error(content, exit) end
  return rmr(path .. PATHSEP .. ".git")
end

local dummy = {
  name = "dummy",
  runnable = function() return false end,
  get = function() error("Client is not loaded") end,
  download_file = function() error("Client is not loaded") end
}

local client
core.add_thread(function()
  local p, c, w = powershell.runnable(), curl.runnable(), wget.runnable()
  if p then
    client = powershell
  elseif c and not client then
    client = curl
  elseif w and not client then
    client = wget
  else
    core.error("No client is available. Remote functions does not work.")
    client = dummy
  end
  core.log_quiet("%s is used to download files.", client.name)
end)


local function magiclines(str)
  if str:sub(-1) ~= "\n" then str = str .. "\n" end
  return str:gmatch("(.-)\n")
end

local function md_table_parse(str)
  local sep = str:find("|", 2, true) -- check if there is a seperator in the middle of string (not the end)
  if not sep or sep == #str then return end

  local matches = {}
  if str:sub(1, 1) ~= "|" then str = "|" .. str end
  if str:sub(-1) == "|" then str = str:sub(1, -2) end
  for content in str:gmatch("|([^|]*)") do
    table.insert(matches, content)
  end
  return matches
end

local function md_parse(str)
  return coroutine.wrap(function()
    local row, last_t = false, "text"
    for line in magiclines(str) do
      local res = md_table_parse(line)
      if not res then
        last_t = "text"
        coroutine.yield("text", line)
      elseif table.concat(res):find("^%-%--%-$") then -- the seperator
        last_t = "sep"
      else
        if last_t == "sep" then row = true end
        if row then
          coroutine.yield("row", res)
        else
          coroutine.yield("header", res)
        end
      end
    end
  end)
end

local function md_url_parse(url)
  return url:match("%[([^%]]-)%]%(([^%)]+)%)")
end

local function md_sanitize(str)
  return str
    :gsub("%*([^%*]-)%*", function(text) return text end) -- remove text formatting
    :gsub("__([^_]-)__", function(text) return text end)
    :gsub("~~([^~]-)~~", function(text) return text end)
    :gsub("_([^_]-)_", function(text) return text end)
    :gsub("`([^`]-)`", function(text) return text end)
    :gsub("%[([^%]]-)%]%(([^%)]+)%)", function(text) return text end) -- remove url
end

local function url_segment(url)
  local res = {}
  if url:sub(-1) == "/" then url = url:sub(1, -2) end
  if url:match("%w+://[^/]+") then
    local first, s = url:match("(%w+://[^/]+)()")
    url = url:sub(s)
    table.insert(res, first)
  end
  for segment in url:gmatch("/[^/]+") do
    table.insert(res, segment)
  end
  return res
end

local services = {}
services.github = {}
function services.github.match(url) return url:match("^https://github.com/[^/]-/[^/]-$") end
function services.github.git_url(url) return url end

services.srht = {}
function services.srht.match(url) return url:match("^https://git.sr.ht/[^/]-/[^/]-$") end
function services.srht.git_url(url) return url end

services.gitlab = {}
function services.gitlab.match(url) return url:match("^https://gitlab.com/[^/]-/[^/]-$") end
function services.gitlab.git_url(url) return url end

local function match_git_services(url)
  for name, v in pairs(services) do
    if v.match(url) then return v, name end
  end
end

local function get_url_filename(url)
  local seg = url_segment(url)
  return seg[#seg]:match("/([^%?#]+)")
end

local function get_remote_plugins(src_url)
  local content, err = client.get(src_url)
  if not content then return error(err) end

  local base_url = url_segment(src_url)
  base_url = table.concat(base_url, "", 1, #base_url - 1)

  local res = {}
  for t, match in md_parse(content) do
    if t == "row" then
      local name, url = md_url_parse(match[1])
      url = url:match("^http") and url or base_url .. "/" .. url
      name = name:match("`([^`]-)`")
      local path = PLUGIN_PATH .. PATHSEP .. get_url_filename(url)
      local description = md_sanitize(match[2])
      local plugin_type = match[1]:find("%*%s-") and "dir" or "file"
      res[name] = {
        name = name,
        url = url,
        path = path,
        description = description,
        type = plugin_type
      }
    end
  end
  return res
end

local function get_local_plugins()
  local res = {}
  for path, stat in scandir(PLUGIN_PATH, 2) do
    local a, b = path:find(PLUGIN_PATH .. PATHSEP, 0, true)
    local relpath = a and path:sub(b + 1) or path
    res[relpath] = {
      name = relpath,
      url = (PLATFORM == "Windows" and "file:///" or "file://") .. path,
      path = path,
      description = string.format("%s, last modified at %s", stat.type, os.date(nil, stat.modified)),
      type = stat.type
    }
  end
  return res
end


local PluginManager = {}

local function noop() end
local function collect_keys(tbl)
  local out, i = {}, 1
  for k, _ in pairs(tbl) do
    out[i] = k
    i = i + 1
  end
  return out
end

local function show_plugins(plugins, callback)
  local list = {}
  for name, info in pairs(plugins) do
    table.insert(list, { text = name .. (info.type == "dir" and "*" or ""), subtext = info.description })
  end
  table.sort(list, function(a, b) return string.lower(a.text) < string.lower(b.text) end)

  local v = ListView(list)
  local node = core.root_view:get_active_node()
  assert(not node.locked, "Cannot open list to a locked node")
  node:split("down", v)

  function v:on_selected(item)
    callback(plugins[item.text])
  end
  function v:try_close(...)
    self.super.try_close(self, ...)
    callback()
  end
end

local function show_options(prompt, opt, callback)
  if not opt[1] then opt = collect_keys(opt) end
  local function on_finish(item)
    callback(#item > 0 and item)
  end
  local function on_cancel()
    callback()
  end
  local function on_suggest(text)
    local res = common.fuzzy_match(opt, text)
    for i, name in ipairs(res) do
      res[i] = { text = name }
    end
    return res
  end
  core.command_view:enter(prompt, on_finish, on_suggest, on_cancel)
end

local function show_move_dest(callback)
  local function on_finish(item)
    callback(#item > 0 and item)
  end
  local function on_cancel()
    callback()
  end
  core.command_view:enter("Move to", on_finish, common.path_suggest, on_cancel)
  core.command_view:set_text(PLUGIN_PATH)
end

local local_actions = {
  ["Delete plugin"] = function(item)
    if not system.show_confirm_dialog("Delete plugin", "Do you really want to delete this plugin?") then
      return core.log("Operation cancelled.")
    end

    core.log("Deleting %s...", item.name)
    local status, err = rmr(item.path)
    if status then
      core.log("%s is deleted.", item.name)
    else
      core.error("Error deleting plugin: %s", err)
    end
  end,
  ["Move plugin"] = function(item)
    local dest = await(show_move_dest)
    if not dest then return core.log("Operation cancelled.") end

    local filename = item.path:match("[/\\]([^/\\]-)$")
    if dest:sub(-1) == "/" or dest:sub(-1) == "\\" then
      local stat = system.get_file_info(dest)
      if stat and stat.type ~= "dir" then
        return core.error("Error creating %q: path exists", dest)
      else
        local status, err = mkdirp(dest)
        if not status then return core.error("Error creating %q: %s", dest, err) end
      end
      dest = dest .. filename
    end

    if dest == item.path then return core.error("Error moving plugin: destination and source are then same") end
    local status, err = os.rename(item.path, dest)
    if not status then
      core.error("Error moving plugin: %s", err)
    else
      core.log("Moved %q to %q.", item.path, dest)
    end
  end
}
local remote_actions = {
  ["Download plugin"] = function(item)
    if item.type == "dir" then
      if not git.runnable() then return core.error("git is not available.") end
      local service = match_git_services(item.url)
      if not service then return core.error("Error cloning repository: invalid provider") end
      local git_url = service.git_url(item.url)

      core.log("Cloning %s...", item.name)
      local status, err = git.clone(git_url, item.path)
      if status then
        return core.log("%s is cloned to %q", item.name, item.path)
      else
        return core.error("Error cloning repository: %s", err)
      end
    else
      core.log("Downloading %s...", item.name)
      local status, err = client.download_file(item.url, item.path)
      if status then
        core.log("%s is installed as %q", item.name, item.path)
      else
        core.error("Error downloading plugin: %s", err)
      end
    end
  end,
  ["Copy plugin URL"] = function(item)
    system.set_clipboard(item.url)
    core.log("URL copied to clipboard.")
  end
}

function PluginManager.list_local()
  local plugins = get_local_plugins()

  for item in await_all(show_plugins, plugins) do
    local opt = await(show_options, "Manage local plugin", local_actions)
    if opt then command.perform "root:close" end

    local action = local_actions[opt] or noop
    action(item)
  end
end

function PluginManager.list_remote()
  core.log("Getting plugin list...")
  local plugins = get_remote_plugins(PLUGIN_URL)

  for item in await_all(show_plugins, plugins) do
    local opt = await(show_options, "Manage remote plugin", remote_actions)
    if opt then command.perform "root:close" end

    local action = remote_actions[opt] or noop
    action(item)
  end
end

local function wrap_coroutine(fn)
  return function()
    core.add_thread(fn)
  end
end

command.add(nil, {
  ["plugin-manager:list-local"]  = wrap_coroutine(PluginManager.list_local),
  ["plugin-manager:list-remote"] = wrap_coroutine(PluginManager.list_remote)
})