# Yazip

Yazip is a plugin that gives you the ability to view and edit archive files as
if they were directories.

Still WIP

Only previewing archive files are working. Opening and editing nested archives
is not supported yet.

## Installation

```
ya pkg add TKperson/yazip
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
  { on = "q",   run = "plugin yazip -- quit",                       desc = "Quit the process" },
  { on = "Q",   run = "plugin yazip -- quit --no-cwd-file",         desc = "Quit without outputting cwd-file" },
  # this defaults to normal l when the hovered item is not a supported archive file
  { on = ["l"], run = "plugin yazip",                               desc = "Enter archive with Yazip" }, 
  { on = ["e"], run = 'plugin yazip -- extract --hovered-selected', desc = "Extract selected or hovered inside of Yazip" },
  { on = ["E"], run = 'plugin yazip -- extract --all',              desc = "Extract everything inside of Yazip" },
]
```
