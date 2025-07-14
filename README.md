# Yazip

Yazip is a Yazi plugin that gives you the ability to view and edit archive
files as if they were regular directories.

Still WIP

What currently works:

* Previewing archive as directory works.
* partially supports editing
  * Normal file operations like cutting, deleting, and renaming are
  supported

What doesn't work:

* Add files/directories that are created inside of the archive file
  * If files are being updated, for example, using vim, the archive file will
  also not get updated.
* Opening nested archives is not supported yet.
* Yanking

## Installation

```sh
ya pkg add TKperson/yazip
```

* `init.lua`
```lua
require("yazip"):setup{
	show_hovered = false,
	archive_indicator_icon = "  ",
	archive_indicator_color = "#ECA517",
}
```

* `yazi.toml`

```toml
[plugin]
prepend_fetchers = [
    { id = "mime", name = "*", run = "yazip", prio = "high" }
]
prepend_previewers = [
    { mime = "yazip/*", run = "yazip" },
]
```

* `keymap.toml`

```toml
[mgr]
prepend_keymap = [
  # extend the default quit event to handle cases when you are inside of an archive file
  { on = ["q"],   run = "plugin yazip -- quit",                       desc = "Quit the process" },
  { on = ["Q"],   run = "plugin yazip -- quit --no-cwd-file",         desc = "Quit without outputting cwd-file" },
  # this defaults to normal l when the hovered item is not a supported archive file
  { on = ["l"], run = "plugin yazip",                               desc = "Enter archive with Yazip" }, 
  { on = ["e"], run = 'plugin yazip -- extract --hovered-selected', desc = "Extract selected or hovered inside of Yazip" },
  { on = ["E"], run = 'plugin yazip -- extract --all',              desc = "Extract everything inside of Yazip" },
]
```

## Known issues

* No support for editing existing files or add new files/directories inside of
an archive file
  * I'm not sure if Yazi plugin system has a way to detect changes made inside
  of a directory.
* Swapping tabs that have different archive files opened will break the plugin
  * reproduce steps: get inside of one archive -> new tab -> leave archive ->
  swap tab
  * I'm unable to find a solution for this because `ps.sub` does not give any
  information about tabs getting swapped
* parent window not does not update when viewing it inside of an archive file
  * Not sure if Yazi plugin system allows a directory to watch for changes.
* Does not support editing UNIX file permission bits
  * Not sure if Yazi has a way to detect permission bits changes
* Yanking files to archive files don't work
  * `cx.yanked` only provides information about where files are yanked from not
  where files are yanked to.
