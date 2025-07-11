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

local current_state = ya.sync(function(st)
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

local set_tmp_path = ya.sync(function(st, archive_path, tmp_path)
	if st.tmp_paths == nil then
		st.tmp_paths = {}
	end

	st.tmp_paths[archive_path] = tmp_path
end)

local get_tmp_path = ya.sync(function(st, archive_path)
	if st.tmp_paths == nil then
		st.tmp_paths = {}
		return nil
	end

	return st.tmp_paths[archive_path]
end)

local set_opened_archive = ya.sync(function(st, archive_path, tab)
	if st.opened_archive == nil then
		st.opened_archive = {}
	end

	st.opened_archive[tab] = archive_path
end)

local get_opened_archive = ya.sync(function(st, tab)
	if st.opened_archive == nil then
		return nil
	end

	return st.opened_archive[tab]
end)

local set_extracted_files = ya.sync(function(st, archive_path, extracted_files, order)
	if st.extracted_files == nil then
		st.extracted_files = {}
	end

	if st.extracted_files_order == nil then
		st.extracted_files_order = {}
	end

	st.extracted_files[archive_path] = extracted_files
	st.extracted_files_order[archive_path] = order
end)

local get_extracted_files = ya.sync(function(st, archive_path)
	if st.extracted_files == nil then
		return {}
	end

	return { st.extracted_files[archive_path], st.extracted_files_order[archive_path] }
end)

-- helper functions --

local function two_deep(archive_path, cwd)
	local tmp_path = get_tmp_path(archive_path)
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

local SevenZip = {}

function SevenZip:is_encrypted(s) return s:find(" Wrong password", 1, true) end

function SevenZip:spawn(args)
	local last_err = nil
	local try = function(name)
		local stdout = args[2] == "l" and Command.PIPED or Command.NULL
		local child, err = Command(name):arg(args):stdout(stdout):stderr(Command.PIPED):spawn()
		if not child then
			last_err = err
		end
		return child
	end

	local child = try("7zz") or try("7z")
	if not child then
		return ya.err("Failed to start either `7zz` or `7z`, error: " .. last_err)
	end
	return child, last_err
end

function SevenZip:get_password(archive_path)
	local value, event = ya.input {
		position = { "center", w = 50 },
		title = string.format('Password for "%s":', Url(archive_path).name),
		obscure = true,
	}
	if event == 1 then
		return value
	end
end


function SevenZip:execute(archive_path, command)
	local pwd = ""
	while true do
		local retry, output = self:try_execute(command, pwd)
		if not retry then
			return output
		end

		pwd = self:get_password(archive_path)
		if pwd == nil then
			return
		end
	end
end

function SevenZip:try_execute(command, pwd)
	ya.dbg("fucking trying to execute", command)
	local child, err = self:spawn{ "-p" .. pwd, table.unpack(command) }

	local output
	output, err = child:wait_with_output()
	if output and output.status.code == 2 and self:is_encrypted(output.stderr) then
		if pwd ~= "" then
			notify("Incorrect password")
		end
		return true, nil -- Need to retry
	end

	return false, output

	-- if not output then
	-- 	ya.err("7zip failed to output when extracting '%s', error: %s", from, err)
	-- elseif output.status.code ~= 0 then
	-- 	ya.err("7zip exited when extracting '%s', error code %s", from, output.status.code)
	-- end
end

function SevenZip:extract(archive_path, destination, inner_paths)
	local command = { "x", "-aoa", "-sccUTF-8", "-o" .. destination, archive_path, table.unpack(inner_paths) }
	return self:execute(archive_path, command)
end

function SevenZip:list_paths(archive_path)
	local output = self:execute(archive_path, { "l", "-ba", "-slt", "-sccUTF-8", archive_path })
	if not output then
		return
	end

	local current_path, paths, order = nil, {}, {}
	local key, value = "", ""
	for line in output.stdout:gmatch("[^\r\n]+") do
		key, value = line:match("([^=]+) = (.+)")
		if key == "Path" then
			current_path = value
			paths[current_path] = { size = 0, attr = "", extracted = false, listed = false }
			order[#order + 1] = current_path
		elseif key == "Size" then
			paths[current_path].size = tonumber(value) or 0
		elseif key == "Attributes" then
			paths[current_path].attr = value
		end
	end

	return paths, order
end

function SevenZip:rename(archive_path, rename_pairs)
	for from, to in pairs(rename_pairs) do
		print("adsf")
	end
end

function SevenZip:update(archive_path, to, with)
end

-- commands --
local function extract_all()
	local st = current_state()
	local archive_path = get_opened_archive(st.active_tab)
	local yazip_path = get_tmp_path(archive_path)
	local output = SevenZip:extract(archive_path, yazip_path, {})

	if not output then
		return -- user didn't enter password
	end

	local paths, order = table.unpack(get_extracted_files(archive_path))
	for _, metadata in pairs(paths) do
		metadata.extracted = true
	end
	set_extracted_files(archive_path, paths, order)

	notify("Finished extracting all archive files")
end

local function extract_hovered_selected()
	local st = current_state()
	local archive_path = get_opened_archive(st.active_tab)
	local tmp_path = get_tmp_path(archive_path)
	local selected_relative = {}
	local listed_paths, order = table.unpack(get_extracted_files(archive_path))

	local warning = false

	local paths = { st.hovered_path }
	local finish_msg = "Extracted the hovered item"
	if #st.selected ~= 0 then
		paths = st.selected
		finish_msg = "Extracted the selected item(s)"
	end

	for _, path in ipairs(paths) do
		local relative_path = tostring(Url(path):strip_prefix(tmp_path))
		if not is_yazip_path(path) then
			warning = true
			goto continue
		end
		-- selected_relative[#selected_relative + 1] = path:sub(#tmp_path + 2, #path)
		selected_relative[#selected_relative + 1] = relative_path
		local metadata = listed_paths[relative_path]
		metadata.extracted = true

		::continue::
	end

	if warning then
		notify("Non-yazip files in the selection are ignored", "warn")
	end

	local output = SevenZip:extract(archive_path, tmp_path, selected_relative)
	if not output then
		return -- user didn't enter password
	end

	set_extracted_files(archive_path, listed_paths, order)
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
		local archive_path = get_opened_archive(st.active_tab)
		if archive_path ~= nil and is_yazip_path(st.hovered_path) then
			local archive_cwd = Url(archive_path).parent
			ya.emit("cd", { tostring(archive_cwd) })
		end

		if args.no_cwd_file then
			ya.emit("quit", { no_cwd_file = true })
		else
			ya.emit("quit", {})
		end
	end
end

-- yazi entries --
local M = {}

function M:entry(job)
	local st = current_state()

	if next(job.args) ~= nil then
		handle_commands(job.args, st)
		return
	end

	if is_supported(st.mime) then
		ya.dbg("Opening archive")
		local paths, order = table.unpack(get_extracted_files(st.hovered_path))

		if not paths then
			paths, order = SevenZip:list_paths(st.hovered_path)
			if paths == nil then
				return
			end
			set_extracted_files(st.hovered_path, paths, order)
		end

		local yazip_path = get_tmp_path(st.hovered_path)
		local tmp_url = (yazip_path and Url(yazip_path)) or Url(get_yazip_dir()):join(random_string(8))
		set_tmp_path(st.hovered_path, tostring(tmp_url))
		set_opened_archive(st.hovered_path, st.active_tab)

		local ok, err = fs.create("dir_all", tmp_url)
		if not ok then
			ya.err("Unable to create " .. tmp_url, err)
			return
		end

		local is_dir = function(path)
			return string.find(path.attr, "D")
		end

		for _, path in ipairs(order) do
			local metadata = paths[path]

			if metadata.listed then
				goto continue
			end

			metadata.listed = true

			if is_dir(metadata) then
				-- create dir
				ok, err = fs.create("dir_all", tmp_url:join(path))
				if not ok then
					ya.err("Unable to create directory" .. tostring(tmp_url), err)
					return
				end
			else
				-- create empty file
				local file_path = tmp_url:join(path)
				local file, err = io.open(tostring(file_path), "w")

				if file then
					file:close()
				else
					ya.err("Unable to create zip file structure in /tmp. Stuck on creating " .. file_path, err)
					return
				end
			end

			::continue::
		end

		set_extracted_files(st.hovered_path, paths, order)

		ya.emit("cd", { tmp_url, raw = true })
	else
		-- use default behavior when not hovering over a supported archive file
		ya.emit("enter", {})
	end
    ::continue::
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
				local inner_archive_path = h_url:sub(#get_tmp_path(archive_path) + 2, #h_url)
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
		local st = current_state()

		-- exit
		if st.cwd_path == get_yazip_dir() then
			local archive_path = Url(get_opened_archive(job.tab))
			if archive_path ~= nil then
				ya.emit("cd", { archive_path.parent })
			end
		end
	end)

	ps.sub("@yank", function(job)
		ya.dbg("@yank job", job)
	end)

	ps.sub("move", function(job)
		ya.dbg("move job", job)
	end)

	ps.sub("rename", function(job)
		ya.dbg("rename job", job)
	end)

	ps.sub("bulk", function(bulk_iter)
		for from, to in pairs(bulk_iter) do
			ya.dbg("bulk job", from, to)
			rename(from, to)
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
	local paths
	for i, file in ipairs(job.files) do
		if file.cha.is_dummy then
			st[i] = false
			goto continue
		end

		if file.cha.len == 0 and is_yazip_path(tostring(file.url)) then
			local current_st = current_state()
			local archive_path = get_opened_archive(current_st.active_tab)

			if paths == nil then
				paths, _ = table.unpack(get_extracted_files(archive_path))
			end

			local tmp_path = get_tmp_path(archive_path)
			local temp = tostring(file.url:strip_prefix(tmp_path))
			local metadata = paths[temp]
			if metadata ~= nil and metadata.extracted then
				unknown[#unknown + 1] = file
			end
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
