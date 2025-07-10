local supported_format = { 
	-- only supports * which matches any character zero or more times
	-- copied and expanded from archive.lua
	"application/zip",
	"application/rar",
	"application/7z*",
	"application/tar",
	"application/gzip",
	"application/xz",
	"application/zstd",
	"application/bzip*",
	"application/lzma",
	"application/compress",
	"application/archive",
	"application/cpio",
	"application/arj",
	"application/xar",
	"application/ms-cab*",
}

-- UTILS --
local function get_tmp_dir()
	return os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
end

local function get_yazip_dir()
	return get_tmp_dir() .. "/yazip"
end

local charset = {}
do -- [0-9a-zA-Z]
	for c = 48, 57 do
		table.insert(charset, string.char(c))
	end
	for c = 65, 90 do
		table.insert(charset, string.char(c))
	end
	for c = 97, 122 do
		table.insert(charset, string.char(c))
	end
end

math.randomseed(os.time())
local function random_string(length)
	local res = ""
	for _ = 1, length do
		res = res .. charset[math.random(1, #charset)]
	end
	return res
end

-- ya.sync --

local state = ya.sync(function(st)
	local h = cx.active.current.hovered
	local selected = {}
	for i, url in pairs(cx.active.selected) do
		selected[i] = tostring(url)
	end

	if h == nil then
		return {}
	end

	return {
		mime = h:mime(),
		hovered_path = tostring(h.url),
		cwd_path = tostring(cx.active.current.cwd),
		active_tab = cx.tabs.idx,
		selected = selected,
	}
end)

local cache_archive = ya.sync(function(st, archive_path, tmp_path)
	if st.cache_archive == nil then
		st.cache_archive = {}
	end

	-- tostring(Url(string)) to clone
	st.cache_archive[archive_path] = tmp_path
end)

local get_cache = ya.sync(function(st, url)
	if st.cache_archive == nil then
		st.cache_archive = {}
		return nil
	end

	return st.cache_archive[url]
end)

local set_opened_archive = ya.sync(function(st, url, tab)
	if st.opened_archive == nil then
		st.opened_archive = {}
	end

	st.opened_archive[tab] = url
end)

local get_opened_archive = ya.sync(function(st, tab)
	if st.opened_archive == nil then
		return nil
	end

	return st.opened_archive[tab]
end)

-- helper functions --

local function two_deep(archive_path, cwd)
	local tmp_path = get_cache(archive_path)
	local inner_path = cwd:sub(#tmp_path + 1, #cwd)
	return inner_path:find("/") ~= nil
end

local is_supported = function(mime)
	if mime == nil then
		return false
	end

	for _, pattern in ipairs(supported_format) do
		local dp = {}
		for i = 1, #mime + 1 do
			dp[i] = {}
			for j = 1, #pattern + 1 do
				dp[i][j] = false
			end
		end

		dp[1][1] = true

		for j = 3, #pattern + 1, 2 do
			dp[1][j] = pattern:sub(j, j) == "*" and dp[1][j - 2]
		end

		for i = 2, #mime + 1 do
			for j = 2, #pattern + 1 do
				if pattern:sub(j - 1, j - 1) ~= "*" then
					dp[i][j] = dp[i - 1][j - 1] and pattern:sub(j - 1, j - 1) == mime:sub(i - 1, i - 1)
				else
					dp[i][j] = dp[i][j - 1] or dp[i - 1][j]
				end
			end
		end

		if dp[#mime + 1][#pattern + 1] then
			return true
		end
	end

	return false
end

---List files in an archive
---@param args table
---@return table files
---@return integer code
---  0: success
---  1: failed to spawn
---  2: wrong password
---  3: partial success
local function list_paths(args)
	local archive = require("archive")
	local child = archive.spawn_7z({ "l", "-ba", "-slt", "-sccUTF-8", table.unpack(args) })
	if not child then
		return {}, 0
	end

	local i, paths, code = 0, { { path = "", size = 0, attr = "" } }, 0
	local key, value = "", ""
	while true do
		local next, event = child:read_line()
		if event == 1 and archive.is_encrypted(next) then
			code = 2
			break
		elseif event == 1 then
			code = 3
			goto continue
		elseif event ~= 0 or next == nil then
			break
		end

		if next == "\n" or next == "\r\n" then
			i = i + 1
			if paths[#paths].path ~= "" then
				paths[#paths + 1] = { path = "", size = 0, attr = "" }
			end
			goto continue
		end

		key, value = next:match("^(%u%l+) = (.-)[\r\n]+")
		if key == "Path" then
			paths[#paths].path = value
		elseif key == "Size" then
			paths[#paths].size = tonumber(value) or 0
		elseif key == "Attributes" then
			paths[#paths].attr = value
		end

		::continue::
	end
	child:start_kill()

	if paths[#paths].path == "" then
		paths[#paths] = nil
	end
	return paths, code
end

local function is_yazip_path(path)
	local yazip_path = get_yazip_dir()
	return path:sub(1, #yazip_path) == yazip_path
end

local function notify(msg, level)
	if level == nil then
		level = "info"
	end

	ya.notify {
	  -- Title.
	  title = "Yazip",
	  -- Content.
	  content = msg,
	  -- Timeout.
	  timeout = 6.5,
	  -- Level, available values: "info", "warn", and "error", default is "info".
	  level = level,
	}
end

local extract = {}

function extract:entry(from, to, args)
	local pwd = ""
	while true do
		if not extract:try_with(Url(from), pwd, Url(to), args) then
			break
		end

		local value, event = ya.input {
			position = { "center", w = 50 },
			title = string.format('Password for "%s":', Url(from).name),
			obscure = true,
		}
		if event == 1 then
			pwd = value
		else
			break
		end
	end
end

function extract:try_with(from, pwd, to, args)
	local archive = require("archive")
	local child, err = archive.spawn_7z { "x", "-aoa", "-sccUTF-8", "-p" .. pwd, "-o" .. tostring(to), tostring(from), table.unpack(args) }

	local output, err = child:wait_with_output()
	if output and output.status.code == 2 and archive.is_encrypted(output.stderr) then
		return true -- Need to retry
	end

	if not output then
		ya.err("7zip failed to output when extracting '%s', error: %s", from, err)
	elseif output.status.code ~= 0 then
		ya.err("7zip exited when extracting '%s', error code %s", from, output.status.code)
	end
end

-- commands --
local function extract_all()
	local st = state()
	local archive_path = get_opened_archive(st.active_tab)
	local yazip_path = get_cache(archive_path)
	extract:entry(archive_path, yazip_path, {})

	notify("Finished extracting all archive files")
end

local function extract_hovered_selected()
	local st = state()
	local archive_path = get_opened_archive(st.active_tab)
	local yazip_path = get_cache(archive_path)
	local selected_relative = {}

	local warning = false

	local paths = { st.hovered_path }
	local finish_msg = "Extracted the hovered item"
	if #st.selected ~= 0 then
		paths = st.selected
		finish_msg = "Extracted the selected item(s)"
	end

	for _, path in ipairs(paths) do
		if not is_yazip_path(path) then
			warning = true
			goto continue
		end
		selected_relative[#selected_relative + 1] = path:sub(#yazip_path + 2, #path)

		::continue::
	end

	if warning then
		notify("Non-yazip files in the selection are ignored", "warn")
	end

	extract:entry(archive_path, yazip_path, selected_relative)

	notify(finish_msg)
end

local function handle_commands(args, st)
	if args[1] == "extract" and is_yazip_path(st.hovered_path) and get_opened_archive(st.active_tab) ~= nil then
		if args.all then
			extract_all()
		elseif args.hovered_selected then
			extract_hovered_selected()
		end
	elseif args[1] == "quit" then
		local archive_path = get_cache(st.active_tab)
		if archive_path ~= nil and is_yazip_path(st.hovered_path) then
			local archive_cwd = Url(archive_path).name
			ya.emit("cd", { archive_cwd })
		end

		if args.no_cwd_file then
			ya.emit("quit", { "--no-cwd-file" })
		else
			ya.emit("quit", {})
		end
	end
end

-- yazi entries --
local M = {}

function M:entry(job)
	local st = state()

	if next(job.args) ~= nil then
		handle_commands(job.args, st)
		return
	end

	if is_supported(st.mime) then
		ya.dbg("Opening archive")
		local pwd = ""
		local paths
		while true do
			local code
			paths, code = list_paths({ "-p"..pwd, st.hovered_path })
			if code == 0 then
				break
			end

			if code == 2 then
				local value, event = ya.input{
					title = string.format('Password for "%s":', Url(st.hovered_path).name),
					position = { "center", w = 50 },
					obscure = true,
				}

				if event == 1 then
					pwd = value
				else
					return
				end
			else
				notify("Failed to start both `7zz` and `7z`. Do you have 7-zip installed?", "error")
			end
		end

		local yazip_path = get_cache(st.hovered_path)
		local tmp_url = (yazip_path and Url(yazip_path)) or Url(get_yazip_dir()):join(random_string(8))
		cache_archive(st.hovered_path, tostring(tmp_url))
		set_opened_archive(st.hovered_path, st.active_tab)

		local ok, err = fs.create("dir_all", tmp_url)
		if not ok then
			ya.err("Unable to create " .. tmp_url, err)
			return
		end

		local is_dir = function(path)
			return string.find(path.attr, "D")
		end

		for _, path in ipairs(paths) do
			if is_dir(path) then
				-- create dir
				ok, err = fs.create("dir_all", tmp_url:join(path.path))
				if not ok then
					ya.err("Unable to create directory" .. tostring(tmp_url), err)
					return
				end
			else
				-- create empty file
				local file_path = tmp_url:join(path.path)
				local file, err = io.open(tostring(file_path), "w")

				if file then
					file:close()
				else
					ya.err("Unable to create zip file structure in /tmp. Stuck on creating " .. file_path, err)
					return
				end
			end
		end

		ya.emit("cd", { tmp_url, raw = true })
	else
		-- use default behavior when not hovering over a supported archive file
		ya.emit("enter", {})
	end
end

function M:setup()
	Header.cwd = function(self)
		local max = self._area.w - self._right_width
		if max <= 0 then
			return ""
		end

		local cwd = tostring(self._current.cwd)
		local archive_path = get_opened_archive(cx.tabs.idx)
		local s
		if is_yazip_path(cwd) and archive_path ~= nil then
			s = ya.readable_path(archive_path)
		else
			s = ya.readable_path(cwd) .. self:flags()
		end
		return ui.Span(ya.truncate(s, { max = max, rtl = true })):style(th.mgr.cwd)
	end

	Header:children_add(function(self)
		local cwd = tostring(self._current.cwd)
		local archive_path = get_opened_archive(cx.tabs.idx)
		local s = ""
		if is_yazip_path(cwd) and archive_path ~= nil then
			if self._current == nil or self._current.hovered == nil then
				s = "  " .. self:flags()
			else
				local h_url = tostring(self._current.hovered.url)
				local inner_archive_path = h_url:sub(#get_cache(archive_path) + 2, #h_url)
				s = "  " .. inner_archive_path .. self:flags()
			end
		end
		return ui.Span(s):fg("#ECA517")
	end, 1100, Header.LEFT)

	local old_new = Parent.new
	function Parent:new(area, tab)
		local archive_path = get_opened_archive(cx.tabs.idx)
		local cwd_path = tostring(cx.active.current.cwd)

		if is_yazip_path(cwd_path) and archive_path ~= nil and not two_deep(archive_path, cwd_path) then
			local archive_name = Url(archive_path).name
			local url = Url(archive_path:sub(1, #archive_path - #archive_name))
			local parent = cx.active:history(url)
			if parent then
				tab = { parent = parent }
			else
				ya.err("Unable to render the correct parent window")
			end
		end

		return old_new(self, area, tab)
	end

	ps.sub("cd", function(job)
		local st = state()

		-- exit
		if st.cwd_path == get_yazip_dir() then
			local archive_path = Url(get_opened_archive(job.tab))
			if archive_path ~= nil then
				ya.emit("cd", { archive_path.parent })
			end
		end
	end)
end

function M.msg(job, s)
	ya.preview_widget(job, ui.Text(ui.Line(s):reverse()):area(job.area):wrap(ui.Wrap.YES))
end

function M:peek(job)
	self.msg(job, "This file is currently not extracted.")
end

function M:seek(job) end

function M:fetch(job)
	local updates, unknown, st = {}, {}, {}
	for i, file in ipairs(job.files) do
		if file.cha.is_dummy then
			st[i] = false
			goto continue
		end

		-- TODO: file.cha.len == 0 includes empty files 
		-- maybe keep track of files that have been extracted
		if file.cha.len == 0 and is_yazip_path(tostring(file.url)) then
			updates[tostring(file.url)], st[i] = "yazip/file", true
		else
			unknown[#unknown + 1] = file
		end

		::continue::
	end

	if next(updates) then
		ya.emit("update_mimes", { updates = updates })
	end

	if #unknown > 0 then
		return self.fallback_fetch(job, unknown, st)
	end

	return st
end

function M.fallback_fetch(job, unknown, st)
	local indices = {}
	for i, f in ipairs(job.files) do
		indices[f:hash()] = i
	end

	local result = require("mime"):fetch(ya.dict_merge(job, { files = unknown }))
	for i, f in ipairs(unknown) do
		if type(result) == "table" then
			st[indices[f:hash()]] = result[i]
		else
			st[indices[f:hash()]] = result
		end
	end
	return st
end

return M
