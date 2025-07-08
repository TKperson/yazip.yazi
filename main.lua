local supported_format = { -- only supports * from regex
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

local function copy_file_parts(file, is_hovered)
	local kind = 0
	-- TODO: handle windowsOS files
	local chakind = { file.is_dir, file.is_hidden, file.is_link, file.is_orphan, file.is_dummy } -- unix
	for i, condition in ipairs(chakind) do
		kind = kind | (condition and 1 << (i - 1))
	end

	return {
		url = tostring(file.url),
		cha = { -- NOTE: unix only currently
			kind = kind,
			len = file.cha.len,
			atime = file.cha.atime,
			btime = file.cha.btime,
			ctime = file.cha.ctime,
			mtime = file.cha.mtime,
			mode = file.cha.mode,
			dev = file.cha.dev,
			uid = file.cha.uid,
			gid = file.cha.gid,
			nlink = file.cha.nlink,
		},
		highlights = file:highlights(),
		style = file:style(),
		icon = file:icon(),
		found = file:found(),
		is_hovered = is_hovered,
	}
end

local function assemble_file_parts(parts)
	-- very hacky workaround
	local f = {}
	f.inner = File({
		url = Url(parts.url),
		cha = Cha(parts.cha),
	})
	f.name = f.inner.name
	f.is_hovered = parts.is_hovered
	f.link_to = f.inner.link_to
	f.in_preview = f.inner.in_preview
	f.cha = f.inner.cha
	f.url = f.inner.url
	function f:prefix()
		return ""
	end
	function f:icon()
		return parts.icon
	end
	function f:found()
		return parts.found
	end
	function f:style()
		return parts.style
	end
	function f:highlights()
		-- return parts.highlights
		-- not needed
		return nil
	end
	return f
end

-- ya.sync --

local get_cache = ya.sync(function(st, url)
	if st.cache_archive == nil then
		st.cache_archive = {}
		return nil
	end

	return st.cache_archive[url]
end)

local set_session_id = ya.sync(function(st, id)
	st.session_id = id
end)

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
		session_id = st.session_id,
		selected = selected,
	}
end)

local cache_archive = ya.sync(function(st, url, tmp_path)
	if st.cache_archive == nil then
		st.cache_archive = {}
	end

	st.cache_archive[url] = tmp_path
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


local save_parent_window = ya.sync(function(st)
	local parent_window = {}
	for i, file in ipairs(cx.active.current.window) do
		-- highlight the archive file
		local is_hovered = false
		if get_opened_archive(cx.tabs.idx) == tostring(file.url) then
			is_hovered = true
		end
		parent_window[i] = copy_file_parts(file, is_hovered)
	end

	st.parent_window = parent_window
end)

local get_parent_window = ya.sync(function(st)
	return st.parent_window
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

local function is_encrypted(s)
	return s:find(" Wrong password", 1, true)
end

local function spawn_7z(args)
	local last_err = nil
	local try = function(name)
		local stdout = args[1] == "l" and Command.PIPED or Command.NULL
		local child, err = Command(name):arg(args):stdout(stdout):stderr(Command.PIPED):spawn()
		if not child then
			last_err = err
		end
		return child
	end

	local child = try("7zz") or try("7z")
	if not child then
		return ya.err("Failed to start both `7zz` and `7z`, error: " .. last_err)
	end
	return child, last_err
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
	local child = spawn_7z({ "l", "-ba", "-slt", "-sccUTF-8", table.unpack(args) })
	if not child then
		return {}, 0
	end

	local i, paths, code = 0, { { path = "", size = 0, attr = "" } }, 0
	local key, value = "", ""
	while true do
		local next, event = child:read_line()
		if event == 1 and is_encrypted(next) then
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

local function extract_all()
	local st = state()
	local archive_path = get_opened_archive(st.active_tab)
	local yazip_path = get_cache(archive_path)
	local child, err = spawn_7z({ "x", archive_path, "-o" .. yazip_path, "-y" })
	if err ~= nil then
		ya.err("Unable to create a 7zip process", err)
	end
	local status, err = child:wait()
	if err ~= nil then
		ya.err("Failed to extract this archive with 7zip", status, err)
	end
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

-- commands --

local function extract_hovered_selected()
	local st = state()
	local archive_path = get_opened_archive(st.active_tab)
	local yazip_path = get_cache(archive_path)
	local selected_relative = {}

	local warning = false

	for _, path in ipairs(st.selected) do
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

	local child, err = spawn_7z({ "e", table.unpack(selected_relative), "-o" .. yazip_path, "-y" })
	if err ~= nil then
		ya.err("Unable to create a 7zip process", err)
	end
	local status, err = child:wait()
	if err ~= nil then
		ya.err("Failed to extract this archive with 7zip", status, err)
	end
end

local function handle_commands(args)
	if args[1] == "extract" then
		if args.all then
			extract_all()
			ya.notify({
				-- Title.
				title = "Yazip",
				-- Content.
				content = "Finished extracting all",
				-- Timeout.
				timeout = 6.5,
				-- Level, available values: "info", "warn", and "error", default is "info".
				level = "info",
			})
		elseif args.hovered_selected then
			extract_hovered_selected()
		end
	end
end

-- yazi entries --
local M = {}

function M:entry(job)
	local st = state()

	if next(job.args) ~= nil and is_yazip_path(st.hovered_path) and get_opened_archive(st.active_tab) ~= nil then
		handle_commands(job.args)
		return
	end

	if is_supported(st.mime) then
		ya.dbg("Opening archive")
		local paths, code = list_paths({ "-p", st.hovered_path })
		if code ~= 0 then
			return require("empty").msg(
				job,
				code == 2 and "File list in this archive is encrypted"
					or "Failed to start both `7zz` and `7z`. Do you have 7-zip installed?"
			)
		end

		local tmp_url = get_cache(st.hovered_path) or get_yazip_dir() .. "/" .. random_string(8)
		cache_archive(st.hovered_path, tmp_url)
		set_opened_archive(st.hovered_path, st.active_tab)
		save_parent_window()

		local ok, err = fs.create("dir_all", Url(tmp_url))
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
				ok, err = fs.create("dir_all", Url(tmp_url .. "/" .. path.path))
				if not ok then
					ya.err("Unable to create directory" .. tostring(tmp_url), err)
					return
				end
			else
				-- create empty file
				local file_path = tmp_url .. "/" .. path.path
				local file, err = io.open(file_path, "w")

				if file then
					file:close()
				else
					ya.err("Unable to create zip file structure in /tmp. Stuck on creating " .. file_path, err)
					return
				end
			end
		end

		ya.emit("cd", { Url(tmp_url), raw = true })
	else
		-- use default behavior when not hovering over a supported archive file
		ya.emit("enter", {})
	end
end

function M:setup()
	ya.dbg("lmao", Folder)
	set_session_id(random_string(5))

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

	Parent.redraw = function(self)
		if not self._folder then
			return {}
		end

		local archive_path = get_opened_archive(cx.tabs.idx)
		local cwd_path = tostring(cx.active.current.cwd)
		local window = {}

		if is_yazip_path(cwd_path) and archive_path ~= nil and not two_deep(archive_path, cwd_path) then
			local parent_window = get_parent_window()
			for i, parts in ipairs(parent_window) do
				window[i] = assemble_file_parts(parts)
			end
		else
			window = self._folder.window
		end

		local items = {}
		for _, f in ipairs(window) do
			local entity = Entity:new(f)
			items[#items + 1] = entity:redraw():truncate({
				max = self._area.w,
				ellipsis = entity:ellipsis(self._area.w),
			})
		end

		return ui.List(items):area(self._area)
	end

	ps.sub("cd", function(job)
		local st = state()

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
