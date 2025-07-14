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

local function by_parent_path(a, b)
	return tostring(Url(a).parent) < tostring(Url(b).parent)
end

local function fill_directories(paths, order)
	table.sort(order, by_parent_path)

	local to_be_inserted = {}
	for i, path in ipairs(order) do
		local parent = Url(path).parent
		while true do
			if parent == nil or tostring(parent) == "" then
				break
			end

			local parent_path = tostring(parent)
			if paths[parent_path] == nil then
				paths[parent_path] = { size = 0, attr = "D", extracted = false, listed = false }
				to_be_inserted[#to_be_inserted+1] = {index = i, dir = parent_path}
			else
				break
			end

			parent = parent.parent
		end
	end

	for i = #to_be_inserted, 1, -1 do
		local item = to_be_inserted[i]
		table.insert(order, item.index, item.dir)
	end
end

-- ya.sync --
local current_state = ya.sync(function()
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
		active_tab = cx.tabs.idx,
		selected = selected,
	}
end)

local tasks_done = ya.sync(function(st)
	ya.dbg("fucking tasks list", st.archive_tasks)
	return #st.archive_tasks == 0
end)

local clear_tasks = ya.sync(function(st)
	st.archive_tasks = {}
end)

local get_session_id = ya.sync(function(st)
	return st.session_id
end)

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local set_tmp_path = ya.sync(function(st, archive_path, tmp_path)
	st.tmp_paths[archive_path] = tmp_path
end)

local get_tmp_path = ya.sync(function(st, archive_path)
	return st.tmp_paths[archive_path]
end)

local set_opened_archive = ya.sync(function(st, archive_path, tab)
	st.opened_archive[tab] = archive_path
end)

local get_opened_archive = ya.sync(function(st, tab)
	return st.opened_archive[tab]
end)

local set_archive_files = ya.sync(function(st, archive_path, archive_files, order)
	st.archive_files[archive_path] = archive_files
	st.archive_files_order[archive_path] = order
end)

local get_archive_files = ya.sync(function(st, archive_path)
	return { st.archive_files[archive_path], st.archive_files_order[archive_path] }
end)

local save_archive_password = ya.sync(function(st, archive_path, password)
	st.saved_passwords[archive_path] = password
end)

local get_archive_password = ya.sync(function(st, archive_path)
	return st.saved_passwords[archive_path]
end)

local get_archive_tasks = ya.sync(function(st)
	return st.archive_tasks
end)

-- helper functions --

local function get_yazip_dir()
	return get_tmp_dir() .. "/yazip." .. get_session_id()
end

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

function SevenZip:is_encrypted(s) return s:find(" Wrong password", 1, true) or s:find("Break signaled", 1, true) end

function SevenZip:spawn(args)
	local last_err = nil
	local try = function(name)
		local child, err = Command(name):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
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
	local pwd = get_archive_password(archive_path) or ""
	while true do
		local retry, output = self:try_execute(command, pwd)
		if not retry then
			save_archive_password(archive_path, pwd)
			return output
		end

		pwd = self:get_password(archive_path)
		if pwd == nil then
			return
		end
	end
end

function SevenZip:try_execute(command, pwd)
	ya.dbg("trying to execute (no password included)", command)
	local child, err
	if pwd == "" then
		child, err = self:spawn{ table.unpack(command) }
	else
		child, err = self:spawn{ "-p" .. pwd, table.unpack(command) }
	end

	local output
	output, err = child:wait_with_output()
	-- status code = 255 means "Break signaled" this happens when it asks for password and stdin got cancelled
	if output and (output.status.code == 2 or output.status.code == 255) and self:is_encrypted(output.stderr) then
		if pwd ~= "" then
			notify("Incorrect password")
		end
		return true, nil -- Need to retry
	end

	if not output then
		ya.err("7zip failed to output when executing", command, tostring(err))
	elseif output.status.code ~= 0 then
		ya.err("7zip exited when while executing", command, output.status.code, output.stderr, output.stdout)
	end

	return false, output

end

function SevenZip:extract(archive_path, destination, inner_paths)
	local command = { "x", "-aoa", "-o" .. destination, archive_path, table.unpack(inner_paths) }
	return self:execute(archive_path, command)
end

function SevenZip:extract_only(archive_path, destination, inner_paths)
	local command = { "e", "-aoa",  "-o" .. destination, archive_path, table.unpack(inner_paths) }
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
	return self:execute(archive_path, { "rn", archive_path, table.unpack(rename_pairs) })
end

function SevenZip:update(archive_path, update_path)
	-- the /./ at the end is used to set relative path to start inside of the archive path
	return self:execute(archive_path, { "u", archive_path, update_path.."/./" })
end

function SevenZip:delete(archive_path, inner_paths)
	return self:execute(archive_path, { "d", archive_path, table.unpack(inner_paths) })
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

	local paths, order = table.unpack(get_archive_files(archive_path))
	for _, metadata in pairs(paths) do
		metadata.extracted = true
	end
	set_archive_files(archive_path, paths, order)

	notify("Finished extracting all archive files")
end

local function extract_hovered_selected()
	local st = current_state()
	local archive_path = get_opened_archive(st.active_tab)
	local tmp_path = get_tmp_path(archive_path)
	local selected_relative = {}
	local listed_paths, order = table.unpack(get_archive_files(archive_path))

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

	set_archive_files(archive_path, listed_paths, order)
	notify(finish_msg)
end

function do_task(task)
	ya.dbg("doing task", task)
	local archive_path = task.archive_path
	local current_paths, current_order = table.unpack(get_archive_files(archive_path))

	-- change must always contains archive_path and type
	local output
	if task.type == "rename" then
		output = SevenZip:rename(archive_path, task.inner_pairs)
		if not output then
			return
		end

		for i = 1, #task.inner_pairs, 2 do
			local from = task.inner_pairs[i]
			local to = task.inner_pairs[i + 1]

			current_paths[to] = current_paths[from]
			current_paths[from] = nil
			for j, path in ipairs(current_order) do
				if path == from then
					current_order[j] = to
					break
				end
			end
		end

		set_archive_files(current_paths, current_order)
	elseif task.type == "extract" then
		output = SevenZip:extract_only(archive_path, task.destination, task.inner_paths)
		if not output then
			return
		end

		-- dont need to handle anything because delete and update will handle everything
	elseif task.type == "update" then
		-- TODO: maybe find a way to make this more efficient?
		output = SevenZip:update(archive_path, task.update_path)
		if not output then
			return
		end

		local paths, order = SevenZip:list_paths(archive_path)
		if paths == nil or order == nil then
			return
		end

		fill_directories(paths, order)
		for _, path in ipairs(order) do
			if current_paths[path] == nil then
				paths[path].listed = true
				paths[path].extracted = true
			else
				paths[path] = current_paths[path]
			end
		end

		set_archive_files(paths, order)
	elseif task.type == "delete" then
		output = SevenZip:delete(archive_path, task.inner_paths)
		if not output then
			return
		end

		for _, inner_path in ipairs(task.inner_paths) do
			current_paths[inner_path] = nil
			for i, path in ipairs(current_order) do
				if path == inner_path then
					table.remove(current_order, i)
					break
				end
			end
		end

		set_archive_files(current_paths, current_order)
	else
		ya.err("unsupported change type", task.archive_path, task.type)
		return
	end

	if output then
		ya.dbg("output log", output.status.code, output.stdout, output.stderr)
	end
end

local function wait_for_tasks()
	while true do
		if tasks_done() then
			break
		end

		ya.sleep(0.1)
	end
end

local function handle_commands(args, st)
	if args[1] == "extract" and is_yazip_path(st.hovered_path) and get_opened_archive(st.active_tab) ~= nil then
		if args.all then
			extract_all()
		elseif args.hovered_selected then
			extract_hovered_selected()
		end
	elseif args[1] == "do_tasks" then
		local tasks = get_archive_tasks()
		for _, task in ipairs(tasks) do
			do_task(task)
		end
		clear_tasks()
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
		wait_for_tasks()

		ya.dbg("Opening archive")
		local paths, order = table.unpack(get_archive_files(st.hovered_path))

		if not paths then
			paths, order = SevenZip:list_paths(st.hovered_path)
			if paths == nil then
				return
			end
			fill_directories(paths, order)
			set_archive_files(st.hovered_path, paths, order)
		end

		local archive_name = Url(st.hovered_path).name
		local yazip_path = get_tmp_path(st.hovered_path)
		local tmp_url = (yazip_path and Url(yazip_path)) or fs.unique_name(Url(get_yazip_dir()):join(archive_name))
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

		set_archive_files(st.hovered_path, paths, order)

		ya.emit("cd", { tmp_url, raw = true })
	else
		-- use default behavior when not hovering over a supported archive file
		ya.emit("enter", {})
	end
end

function M:setup(user_opts)
	local st = self
	st.session_id = random_string(5)
	st.tmp_paths = {}
	st.opened_archive = {}
	st.archive_files = {}
	st.archive_files_order = {}
	st.saved_passwords = {}
	st.archive_tasks = {}

	-- default opts
	local opts = {
		show_hovered = false,
		archive_indicator_icon = "  ",
		archive_indicator_color = "#ECA517",
	}

	if user_opts == nil then
		user_opts = {}
	end

	for opt, value in pairs(user_opts) do
		opts[opt] = value
	end

	local previous_tab_length = 1
	local last_tab_idx = 1

	local function insert(t, pos, value)
		if pos > #t then
			t[pos] = value
			return
		end

		for i = #t, pos, -1 do
			t[i+1] = t[i]
		end

		t[pos] = value
	end

	local function remove(t, pos)
		if pos > #t then
			return
		end

		for i = pos, #t - 1 do
			t[i] = t[i + 1]
		end

		t[#t] = nil
	end

	local function url_to_archive(url)
		for archive_path, tmp_path in pairs(st.tmp_paths) do
			if url:starts_with(tmp_path) then
				return archive_path
			end
		end
	end

	local function save_tasks(tasks)
		if #tasks > 0 then
			-- extends st.archive_tasks with tasks
			for i = 1, #tasks do
				st.archive_tasks[#st.archive_tasks+1] = tasks[i]
			end
			ya.emit("plugin", {self._id , "do_tasks"})
		end
	end

	Header.cwd = function(self)
		local max = self._area.w - self._right_width
		if max <= 0 then
			return ""
		end

		local cwd = self._current.cwd
		local archive_path = url_to_archive(cwd)
		local s
		if archive_path ~= nil then
			s = ya.readable_path(archive_path)
		else
			s = ya.readable_path(tostring(cwd)) .. self:flags()
		end
		return ui.Span(ya.truncate(s, { max = max, rtl = true })):style(th.mgr.cwd)
	end

	Header:children_add(function(self)
		local cwd = self._current.cwd
		local archive_path = url_to_archive(cwd)
		local s = ""
		if archive_path ~= nil then
			if self._current.hovered == nil or not opts.show_hovered then
				local tmp_path = st.tmp_paths[archive_path]
				local inner_archive_path = cwd:strip_prefix(tmp_path)
				s =  opts.archive_indicator_icon .. inner_archive_path .. self:flags()
			else
				local h_url = tostring(self._current.hovered.url)
				local inner_archive_path = h_url:sub(#get_tmp_path(archive_path) + 2, #h_url)
				s = opts.archive_indicator_icon .. inner_archive_path .. self:flags()
			end
		end
		return ui.Span(s):fg(opts.archive_indicator_color)
	end, 1100, Header.LEFT)

	local function find_archive_parent_tab(archive_path)
		for i, path in ipairs(st.opened_archive) do
			if archive_path == path then
				return i
			end
		end
	end

	local old_new = Parent.new
	function Parent:new(area, tab)
		local archive_path = url_to_archive(cx.active.current.cwd)
		local cwd_path = tostring(cx.active.current.cwd)

		if archive_path ~= nil and not two_deep(archive_path, cwd_path) then
			local url = Url(archive_path).parent
			local tab_index = find_archive_parent_tab(archive_path)
			-- FIXME: correct the hovering position when exiting the archive file
			local parent = cx.tabs[tab_index]:history(url)
			if parent then
				tab = { parent = parent }
			else
				ya.err("Unable to render the correct parent window")
			end
		end

		return old_new(self, area, tab)
	end

	ps.sub("cd", function(job)
		local cwd_path = get_cwd()

		-- exit
		if cwd_path == get_yazip_dir() then
			local archive_path = get_opened_archive(job.tab)
			if archive_path ~= nil then
				ya.emit("cd", { Url(archive_path).parent })
			else
				ya.err("The archive path is nil when exiting on tab #" .. tostring(job.tab))
			end
		end
	end)

	ps.sub("load", function(job)
		-- detect new files/folders
		-- ya.dbg("load job", job)
	end)

	-- FIXME: handle tab swapping
	ps.sub("tab", function(job)
		if previous_tab_length ~= #cx.tabs and is_yazip_path(tostring(cx.active.current.cwd)) then
			if previous_tab_length < #cx.tabs then
				insert(st.opened_archive, job.idx, st.opened_archive[job.idx - 1])
			elseif previous_tab_length > #cx.tabs then
				remove(st.opened_archive, last_tab_idx)
			end
		end
		last_tab_idx = job.idx
		previous_tab_length = #cx.tabs
	end)

	ps.sub("@yank", function()
		if cx.yanked.is_cut then
			return -- handled in `ps.sub("move", callback)`
		end

		local tasks = {}

		for _, url in pairs(cx.yanked) do
			local archive_path = url_to_archive(url)
			if archive_path ~= nil then
				local tmp_path = st.tmp_paths[archive_path]
				tasks[#tasks+1] = {type = "update", archive_path = archive_path, update_path = tmp_path}
			end
		end

		save_tasks(tasks)
	end)

	ps.sub("move", function(job)
		local tasks = {}
		local extract_tasks = {}
		local update_tasks = {}

		for _, item in ipairs(job.items) do
			local from = tostring(item.from)
			local to = tostring(item.to)
			local from_archive_path = url_to_archive(item.from)
			local to_archive_path = url_to_archive(item.to)
			if from_archive_path ~= nil then
				local archive_path = tostring(from_archive_path)
				if extract_tasks[archive_path] == nil then
					extract_tasks[archive_path] = {}
				end
				extract_tasks[archive_path][#extract_tasks[archive_path]+1] = {from = from, to = to}
			end

			if to_archive_path ~= nil then
				local archive_path = tostring(to_archive_path)
				update_tasks[archive_path] = st.tmp_paths[archive_path]
			end
		end

		-- converting to tasks
		for archive_path, locations in pairs(extract_tasks) do
			local destination = locations[1].to
			local inner_paths = {}
			local tmp_path = st.tmp_paths[archive_path]

			for _, location in ipairs(locations) do
				if destination ~= location.to then
					notify("There should only be one destination", "error")
					return
				end
				inner_paths[#inner_paths+1] = tostring(Url(location.from):strip_prefix(tmp_path))
			end

			tasks[#tasks+1] = {
				type = "extract",
				archive_path = archive_path,
				destination = tostring(Url(destination).parent),
				inner_paths = inner_paths,
			}

			tasks[#tasks+1] = {
				type = "delete",
				archive_path = archive_path,
				inner_paths = inner_paths,
			}
		end
		for archive_path, tmp_path in pairs(update_tasks) do
			tasks[#tasks+1] = {
				type = "update",
				archive_path = archive_path,
				update_path = tmp_path
			}
		end
		save_tasks(tasks)
	end)

	ps.sub("rename", function(job)
		local archive_path = url_to_archive(job.to)

		if archive_path ~= nil then
			local tmp_path = st.tmp_paths[archive_path]

			if tmp_path ~= nil then
				local rename_pairs = {
					tostring(job.from:strip_prefix(tmp_path)),
					tostring(job.to:strip_prefix(tmp_path))
				}
				local task = {type = "rename", archive_path = archive_path, inner_pairs = rename_pairs}
				save_tasks({ task })
			end

		end
	end)

	ps.sub("bulk", function(bulk_iter)
		local rename_pairs = {}

		for from, to in pairs(bulk_iter) do
			local archive_path = url_to_archive(from)

			if archive_path ~= nil then
				local tmp_path = st.tmp_paths[archive_path]

				if rename_pairs[archive_path] == nil then
					rename_pairs[archive_path] = {
						type = "rename",
						archive_path = archive_path,
						inner_pairs = {}
					}
				end

				local from_inner = tostring(from:strip_prefix(tmp_path))
				local to_inner = tostring(to:strip_prefix(tmp_path))

				rename_pairs[archive_path].inner_pairs[#rename_pairs[archive_path].inner_pairs+1] = from_inner
				rename_pairs[archive_path].inner_pairs[#rename_pairs[archive_path].inner_pairs+1] = to_inner
			end
		end

		local tasks = {}
		for _, task in pairs(rename_pairs) do
			tasks[#tasks+1] = task
		end

		save_tasks(tasks)
	end)

	ps.sub("delete", function(job)
		local tasks_per_archive = {}

		for _, url in ipairs(job.urls) do
			local archive_path = url_to_archive(url)

			if archive_path ~= nil then
				local tmp_path = st.tmp_paths[archive_path]
				local inner_path = url:strip_prefix(tmp_path)

				if tasks_per_archive[archive_path] == nil then
					tasks_per_archive[archive_path] = {
						type = "delete",
						archive_path = archive_path,
						inner_paths = {}
					}
				end

				tasks_per_archive[archive_path].inner_paths[#tasks_per_archive[archive_path].inner_paths+1] = tostring(inner_path)
			end
		end

		local tasks = {}
		for _, task in pairs(tasks_per_archive) do
			tasks[#tasks+1] = task
		end

		save_tasks(tasks)
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
			-- handle empty file vs unextracted file
			local current_st = current_state()
			local archive_path = get_opened_archive(current_st.active_tab)

			if paths == nil then
				paths, _ = table.unpack(get_archive_files(archive_path))
			end

			local tmp_path = get_tmp_path(archive_path)
			local temp = tostring(file.url:strip_prefix(tmp_path))
			local metadata = paths[temp]
			if metadata ~= nil and metadata.extracted then
				unknown[#unknown + 1] = file
			end
			--

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
