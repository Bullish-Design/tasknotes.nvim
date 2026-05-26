# tasknotes.nvim Fork Refactoring Concept

## Goal

Refactor `tasknotes.nvim` into a more extensible, plugin-first task system by adding:

1. A first-class lifecycle hook system.
2. Synchronous mutation callbacks for create/update/delete operations.
3. Obsidian-style `User` autocmd events.
4. A stable task identity field.
5. A body-aware task update API.
6. A better `input-form.nvim` based task creation/editing UI.
7. Cleaner public Lua APIs for external consumers.

The fork should keep TaskNotes as the owner of task lifecycle, task files, task parsing, task cache, task views, and task UI.

---

## 1. Add a TaskNotes hook layer

Create:

```text
lua/tasknotes/hooks.lua
```

Responsibilities:

```lua
local M = {}

M.events = {
  SETUP_POST = "TaskNotesSetupPost",

  TASK_CREATE_PRE = "TaskNotesTaskCreatePre",
  TASK_CREATE_POST = "TaskNotesTaskCreatePost",

  TASK_UPDATE_PRE = "TaskNotesTaskUpdatePre",
  TASK_UPDATE_POST = "TaskNotesTaskUpdatePost",

  TASK_DELETE_PRE = "TaskNotesTaskDeletePre",
  TASK_DELETE_POST = "TaskNotesTaskDeletePost",

  TASK_OPEN = "TaskNotesTaskOpen",
  TASK_SCAN_POST = "TaskNotesScanPost",
  TASK_REFRESH_POST = "TaskNotesTaskRefreshPost",
}

function M.emit(event_name, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = event_name,
    data = data,
  })
end

function M.run_callback(callback_name, ctx)
  local opts = require("tasknotes.config").get()
  local cb = opts.callbacks and opts.callbacks[callback_name]

  if type(cb) == "function" then
    return cb(ctx)
  end
end

return M
```

This gives the fork two extension surfaces:

```text
setup callbacks  -> synchronous mutation hooks
User autocmds    -> event notification hooks
```

Use setup callbacks for any hook that needs to mutate task data before writing. Use `User` autocmds for observability and post-operation integrations.

---

## 2. Add callback configuration

Extend `lua/tasknotes/config.lua`:

```lua
callbacks = {
  before_task_create = nil,
  after_task_create = nil,

  before_task_update = nil,
  after_task_update = nil,

  before_task_delete = nil,
  after_task_delete = nil,

  after_scan = nil,
  after_refresh = nil,

  on_task_open = nil,
}
```

Each callback receives a mutable context table.

Recommended context shape:

```lua
---@class tasknotes.HookContext
---@field operation string
---@field task table|nil
---@field old_task table|nil
---@field task_data table|nil
---@field updates table|nil
---@field frontmatter table|nil
---@field body string|nil
---@field path string|nil
---@field old_path string|nil
---@field opts table
---@field cancel boolean|nil
---@field error string|nil
---@field metadata table
```

Cancellation convention:

```lua
local ret = hooks.run_callback("before_task_create", ctx)

if ret == false or ctx.cancel then
  vim.notify(ctx.error or "Task creation cancelled", vim.log.levels.WARN)
  return nil
end
```

This should be supported for:

```text
before_task_create
before_task_update
before_task_delete
```

---

## 3. Instrument `task_manager.create_task`

Refactor `create_task` from a direct write function into a lifecycle pipeline.

Current conceptual flow:

```text
task_data
  -> filename
  -> frontmatter
  -> parser.write_file
  -> create task object
  -> update cache
```

New flow:

```text
task_data
  -> normalize task data
  -> generate path
  -> build frontmatter
  -> before_task_create callback
  -> TaskNotesTaskCreatePre autocmd
  -> validate final context
  -> write file
  -> create task object
  -> update in-memory cache
  -> update persistent cache
  -> after_task_create callback
  -> TaskNotesTaskCreatePost autocmd
  -> return task
```

Suggested implementation shape:

```lua
function M.create_task(task_data)
  local opts = config.get()

  task_data = M.normalize_task_data(task_data)

  local filepath = task_data.path or M.generate_task_path(task_data)
  local frontmatter = M.build_frontmatter(task_data, opts)
  local body = task_data.body or ""

  local ctx = {
    operation = "create",
    task_data = task_data,
    frontmatter = frontmatter,
    body = body,
    path = filepath,
    opts = opts,
    metadata = {},
  }

  local ret = hooks.run_callback("before_task_create", ctx)

  if ret == false or ctx.cancel then
    vim.notify(ctx.error or "Task creation cancelled", vim.log.levels.WARN)
    return nil
  end

  hooks.emit(hooks.events.TASK_CREATE_PRE, ctx)

  local valid, err = M.validate_create_context(ctx)
  if not valid then
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end

  local success, write_err = parser.write_file(ctx.path, ctx.frontmatter, ctx.body)
  if not success then
    vim.notify(write_err, vim.log.levels.ERROR)
    return nil
  end

  local task = M.create_task_object(ctx.path, ctx.frontmatter, ctx.body)
  M.add_task_to_cache(task)

  ctx.task = task

  hooks.run_callback("after_task_create", ctx)
  hooks.emit(hooks.events.TASK_CREATE_POST, ctx)

  vim.notify("Created task: " .. vim.fn.fnamemodify(ctx.path, ":t"), vim.log.levels.INFO)

  return task
end
```

Add helper functions:

```lua
M.normalize_task_data(task_data)
M.generate_task_path(task_data)
M.build_frontmatter(task_data, opts)
M.validate_create_context(ctx)
M.add_task_to_cache(task)
```

This keeps `create_task` readable and gives future integrations a stable pre-write mutation point.

---

## 4. Instrument `task_manager.update_task`

Current behavior updates frontmatter and preserves body. The fork should allow body-aware updates and lifecycle hooks.

New flow:

```text
parse existing task file
  -> build context
  -> before_task_update callback
  -> TaskNotesTaskUpdatePre autocmd
  -> validate final updates
  -> apply updates to frontmatter
  -> update body if provided
  -> update modified timestamp
  -> write file
  -> refresh task object
  -> update cache
  -> after_task_update callback
  -> TaskNotesTaskUpdatePost autocmd
  -> return true
```

Recommended API:

```lua
task_manager.update_task(filepath, updates, opts)
```

Where:

```lua
opts = {
  body = "new markdown body",
}
```

Do **not** store `body` inside frontmatter.

Implementation shape:

```lua
function M.update_task(filepath, updates, update_opts)
  update_opts = update_opts or {}

  local parsed = parser.parse_file(filepath)
  if not parsed then
    vim.notify("Could not read task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  local old_task = M.get_task_by_path(filepath)
  local opts = config.get()

  local ctx = {
    operation = "update",
    task = old_task,
    old_task = old_task and vim.deepcopy(old_task) or nil,
    path = filepath,
    updates = updates or {},
    frontmatter = parsed.frontmatter,
    body = update_opts.body or parsed.body,
    opts = opts,
    metadata = {},
  }

  local ret = hooks.run_callback("before_task_update", ctx)

  if ret == false or ctx.cancel then
    vim.notify(ctx.error or "Task update cancelled", vim.log.levels.WARN)
    return false
  end

  hooks.emit(hooks.events.TASK_UPDATE_PRE, ctx)

  local valid, err = M.validate_update_context(ctx)
  if not valid then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  M.apply_updates_to_frontmatter(ctx.frontmatter, ctx.updates, opts)

  local fm = opts.field_mapping
  ctx.frontmatter[fm.dateModified] = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local success, write_err = parser.write_file(ctx.path, ctx.frontmatter, ctx.body)
  if not success then
    vim.notify(write_err, vim.log.levels.ERROR)
    return false
  end

  local task = M.create_task_object(ctx.path, ctx.frontmatter, ctx.body)
  M.replace_task_in_cache(task)

  ctx.task = task

  hooks.run_callback("after_task_update", ctx)
  hooks.emit(hooks.events.TASK_UPDATE_POST, ctx)

  return true
end
```

Add helper functions:

```lua
M.validate_update_context(ctx)
M.apply_updates_to_frontmatter(frontmatter, updates, opts)
M.replace_task_in_cache(task)
```

---

## 5. Instrument `task_manager.delete_task`

Refactor delete into a lifecycle-aware operation.

New flow:

```text
resolve task
  -> before_task_delete callback
  -> TaskNotesTaskDeletePre autocmd
  -> delete file
  -> remove from memory
  -> remove from persistent cache
  -> after_task_delete callback
  -> TaskNotesTaskDeletePost autocmd
```

Implementation shape:

```lua
function M.delete_task(filepath)
  local task = M.get_task_by_path(filepath)

  local ctx = {
    operation = "delete",
    task = task,
    path = filepath,
    opts = config.get(),
    metadata = {},
  }

  local ret = hooks.run_callback("before_task_delete", ctx)

  if ret == false or ctx.cancel then
    vim.notify(ctx.error or "Task deletion cancelled", vim.log.levels.WARN)
    return false
  end

  hooks.emit(hooks.events.TASK_DELETE_PRE, ctx)

  local success = os.remove(filepath)
  if not success then
    vim.notify("Could not delete task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  M.remove_task_from_cache(filepath)

  hooks.run_callback("after_task_delete", ctx)
  hooks.emit(hooks.events.TASK_DELETE_POST, ctx)

  vim.notify("Deleted task", vim.log.levels.INFO)
  return true
end
```

Add helper:

```lua
M.remove_task_from_cache(filepath)
```

---

## 6. Add stable task IDs

Add `id` to the field mapping:

```lua
field_mapping = {
  id = "id",
  title = "title",
  status = "status",
  priority = "priority",
  due = "due",
  scheduled = "scheduled",
  contexts = "contexts",
  projects = "projects",
  tags = "tags",
  timeEstimate = "timeEstimate",
  timeEntries = "timeEntries",
  completedDate = "completedDate",
  dateCreated = "dateCreated",
  dateModified = "dateModified",
  recurrence = "recurrence",
  recurrence_anchor = "recurrence_anchor",
  complete_instances = "complete_instances",
  skipped_instances = "skipped_instances",
  blockedBy = "blockedBy",
  archived = "archived",
}
```

When creating a task:

```lua
frontmatter[fm.id] = task_data.id or M.generate_task_id(task_data.title)
```

Suggested ID format:

```lua
function M.generate_task_id(title)
  local slug = title
    :lower()
    :gsub("%s+", "-")
    :gsub("[^%w%-]", "")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")

  return "task-" .. os.date("!%Y%m%d%H%M%S") .. "-" .. slug
end
```

Update `create_task_object`:

```lua
id = normalize_value(frontmatter[fm.id], nil),
```

Add new caches:

```lua
M.tasks_by_id = {}
```

Update all cache mutation paths:

```lua
M.tasks_by_id[task.id] = task
```

Add public lookup:

```lua
function M.get_task_by_id(id)
  return M.tasks_by_id[id]
end
```

Add resolver:

```lua
function M.resolve_task(ref)
  if not ref then
    return nil
  end

  if M.tasks_by_path[ref] then
    return M.tasks_by_path[ref]
  end

  if M.tasks_by_id[ref] then
    return M.tasks_by_id[ref]
  end

  return nil
end
```

This lets future APIs accept either path or ID.

---

## 7. Replace the current task form with `input-form.nvim`

The current form is a NUI text buffer that renders lines like:

```text
Title:
Status:
Priority:
Due Date:
Contexts:
Projects:
Tags:
```

The fork should replace this with the improved `input-form.nvim` based form.

Recommended file layout:

```text
lua/tasknotes/ui/task_form.lua
lua/tasknotes/ui/form_fields.lua
lua/tasknotes/ui/form_validation.lua
```

### `task_form.lua`

Owns:

```lua
M.new_task(opts)
M.edit_task(task, opts)
M.edit_current_buffer()
M.show_form(task, opts, on_save)
```

### `form_fields.lua`

Owns field construction:

```lua
M.create_task_fields(task, opts)
M.task_to_form_values(task)
M.form_values_to_task_data(values)
```

### `form_validation.lua`

Owns validation:

```lua
M.validate_task_data(data)
M.validate_date(value, field_name)
M.validate_time_estimate(value)
M.normalize_csv(value)
```

---

## 8. New task form fields

The new form should support:

```text
title
status
priority
due
scheduled
contexts
projects
tags
blockedBy
timeEstimate
body
```

Recommended field behavior:

| Field | Type | Behavior |
|---|---|---|
| `title` | text | required |
| `status` | select | from `config.statuses` |
| `priority` | select | from `config.priorities` |
| `due` | text/date | optional, validate `YYYY-MM-DD` |
| `scheduled` | text/date | optional, validate `YYYY-MM-DD` |
| `contexts` | text | comma-separated list |
| `projects` | text | comma-separated list |
| `tags` | text | comma-separated list |
| `blockedBy` | text | comma-separated paths or IDs |
| `timeEstimate` | number/text | optional integer minutes |
| `body` | multiline | Markdown body |

The form should return structured data:

```lua
{
  title = "Write proposal",
  status = "open",
  priority = "normal",
  due = "2026-06-01",
  scheduled = nil,
  contexts = { "work" },
  projects = { "proposal" },
  tags = { "task" },
  blockedBy = {},
  timeEstimate = 45,
  body = "Markdown body..."
}
```

---

## 9. Make the form backend configurable

Extend config:

```lua
ui = {
  border_style = "rounded",
  task_form_width = 60,
  task_form_height = 20,
  time_tracker_width = 50,
  time_tracker_height = 15,

  form_backend = "input-form",
  fallback_to_nui = true,
}
```

Behavior:

```lua
if opts.ui.form_backend == "input-form" and has_input_form then
  use input-form implementation
elseif opts.ui.fallback_to_nui then
  use legacy NUI implementation
else
  vim.notify("input-form.nvim is required for TaskNotes form", vim.log.levels.ERROR)
end
```

For the fork, the preferred default should be:

```lua
form_backend = "input-form"
fallback_to_nui = true
```

This preserves compatibility while making the improved form the default.

---

## 10. Improve dependency checking

Current setup hard-checks `bases.nvim`, `nui.nvim`, and `snacks.nvim`.

Refine dependency checks:

```text
required:
  bases.nvim

conditionally required:
  snacks.nvim if picker.enabled = true
  nui.nvim if legacy form or time tracker is enabled
  input-form.nvim if ui.form_backend = "input-form"

optional:
  plenary.nvim
```

Suggested behavior:

```lua
if opts.ui.form_backend == "input-form" then
  local has_input_form = pcall(require, "input-form")
  if not has_input_form and not opts.ui.fallback_to_nui then
    table.insert(errors, "input-form.nvim not found")
  end
end
```

Do not hard-fail on `snacks.nvim` if the picker is disabled.

Do not hard-fail on `nui.nvim` if neither legacy form nor time tracker is used.

---

## 11. Add body-aware form editing

Current edit flow should become:

```text
get current task
  -> parse full file
  -> populate form from frontmatter and body
  -> submit form
  -> call task_manager.update_task(path, updates, { body = body })
```

Implementation shape:

```lua
function M.edit_task(task)
  local parser = require("tasknotes.parser")
  local parsed = parser.parse_file(task.path)

  if not parsed then
    vim.notify("Could not parse task file", vim.log.levels.ERROR)
    return
  end

  local initial_values = form_fields.task_to_form_values(task)
  initial_values.body = parsed.body or ""

  M.show_form(initial_values, {
    mode = "edit",
  }, function(data)
    local body = data.body
    data.body = nil

    local success = task_manager.update_task(task.path, data, {
      body = body,
    })

    if success then
      vim.notify("Task updated", vim.log.levels.INFO)

      if vim.api.nvim_buf_get_name(0) == task.path then
        vim.cmd("edit!")
      end
    end
  end)
end
```

---

## 12. Improve path and filename generation

Extract filename logic from `create_task`.

Add config:

```lua
task_file = {
  filename_template = "{{slug}}.md",
  id_in_filename = false,
}
```

Helpers:

```lua
M.slugify_title(title)
M.generate_filename(task_data, opts)
M.generate_task_path(task_data, opts)
```

Default behavior should remain compatible:

```text
"My New Task" -> my-new-task.md
```

But the fork should allow future-safe options:

```lua
task_file = {
  filename_template = "{{date}}-{{slug}}.md",
}
```

or:

```lua
task_file = {
  filename_template = "{{id}}.md",
}
```

This is useful because task titles may change while task identity should remain stable.

---

## 13. Add public task APIs

Expose clean APIs from `lua/tasknotes/init.lua`:

```lua
function M.create_task(task_data, opts)
  return task_manager.create_task(task_data, opts)
end

function M.update_task(ref, updates, opts)
  local task = task_manager.resolve_task(ref)
  if not task then
    vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR)
    return false
  end

  return task_manager.update_task(task.path, updates, opts)
end

function M.delete_task(ref, opts)
  local task = task_manager.resolve_task(ref)
  if not task then
    vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR)
    return false
  end

  return task_manager.delete_task(task.path, opts)
end

function M.get_task(ref)
  return task_manager.resolve_task(ref)
end

function M.get_task_by_id(id)
  return task_manager.get_task_by_id(id)
end

function M.get_task_by_path(path)
  return task_manager.get_task_by_path(path)
end
```

Keep existing UI APIs:

```lua
M.new_task()
M.edit_task()
M.browse_tasks()
M.browse_by_view()
M.show_view_selector()
M.toggle_timer()
```

Commands should remain UI-facing. Lua APIs should be integration-facing.

---

## 14. Emit setup, scan, refresh, and open events

### Setup

At the end of `setup()`:

```lua
hooks.run_callback("after_setup", {
  operation = "setup",
  opts = opts,
  metadata = {},
})

hooks.emit(hooks.events.SETUP_POST, {
  operation = "setup",
  opts = opts,
  metadata = {},
})
```

You may name the callback either:

```lua
after_setup
```

or:

```lua
setup_post
```

Use one convention consistently. I would use `after_setup`.

### Scan

At the end of `scan_vault()`:

```lua
local ctx = {
  operation = "scan",
  tasks = M.tasks,
  task_count = #M.tasks,
  opts = config.get(),
  metadata = {
    force_validate = force_validate,
  },
}

hooks.run_callback("after_scan", ctx)
hooks.emit(hooks.events.TASK_SCAN_POST, ctx)
```

### Refresh

At the end of `refresh_task(filepath)`:

```lua
local ctx = {
  operation = "refresh",
  task = task,
  path = filepath,
  opts = config.get(),
  metadata = {},
}

hooks.run_callback("after_refresh", ctx)
hooks.emit(hooks.events.TASK_REFRESH_POST, ctx)
```

### Open

When opening a task from picker or after creation:

```lua
local ctx = {
  operation = "open",
  task = task,
  path = task.path,
  opts = config.get(),
  metadata = {},
}

hooks.run_callback("on_task_open", ctx)
hooks.emit(hooks.events.TASK_OPEN, ctx)
```

---

## 15. Add hook documentation

Create:

```text
docs/hooks.md
```

Document:

```text
Callbacks
Autocmds
Context payloads
Cancellation behavior
Mutation behavior
Examples
```

Example callback documentation:

```lua
require("tasknotes").setup({
  callbacks = {
    before_task_create = function(ctx)
      ctx.frontmatter.custom_field = "example"
    end,

    after_task_create = function(ctx)
      print("Created task:", ctx.task.title)
    end,
  },
})
```

Example autocmd documentation:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "TaskNotesTaskCreatePost",
  callback = function(ev)
    local task = ev.data and ev.data.task
    if task then
      print("Created:", task.title)
    end
  end,
})
```

Document that `before_*` callbacks are the correct mechanism for mutation. `User` autocmds are for observation and follow-up behavior.

---

## 16. Add tests around lifecycle behavior

Add tests for:

```text
before_task_create can mutate frontmatter
before_task_create can mutate body
before_task_create can cancel creation
after_task_create receives task object
before_task_update can mutate updates
before_task_update can mutate body
before_task_update can cancel update
after_task_update receives old_task and task
before_task_delete can cancel deletion
after_task_delete receives deleted task metadata
task IDs are generated
tasks_by_id lookup works
body editing does not create frontmatter.body
input-form data normalizes CSV fields
date validation rejects invalid dates
```

Even if the project does not currently have a full test harness, these should be represented as Plenary tests or minimal Lua integration tests.

---

## 17. Migration compatibility

Existing users should not need to change basic config.

Keep compatible:

```lua
require("tasknotes").setup({
  vault_path = "...",
  statuses = { ... },
  priorities = { ... },
  field_mapping = { ... },
})
```

Keep existing commands:

```text
:TaskNotesBrowse
:TaskNotesNew
:TaskNotesEdit
:TaskNotesRescan
:TaskNotesView
```

Keep existing fields:

```yaml
title:
status:
priority:
due:
scheduled:
contexts:
projects:
tags:
timeEstimate:
blockedBy:
dateCreated:
dateModified:
```

Add `id` only to newly created tasks. For existing tasks without IDs, either:

1. Leave them without IDs until edited, or
2. Add a command to backfill IDs.

Recommended command:

```text
:TaskNotesBackfillIds
```

Behavior:

```text
scan all tasks
for each task without id:
  generate id
  write frontmatter
  refresh cache
```

Do not silently rewrite all task files on setup.

---

## 18. Recommended implementation order

### Phase 1: Hook substrate

Add:

```text
lua/tasknotes/hooks.lua
callbacks config
hook documentation scaffold
```

Instrument:

```text
setup
scan_vault
refresh_task
create_task
update_task
delete_task
```

No UI changes yet.

### Phase 2: Task identity

Add:

```text
field_mapping.id
generate_task_id()
task.id
tasks_by_id
get_task_by_id()
resolve_task()
```

Update all cache mutation paths.

### Phase 3: Body-aware updates

Refactor:

```text
task_manager.update_task(filepath, updates, opts)
```

Add:

```text
opts.body
validate_update_context()
apply_updates_to_frontmatter()
```

Ensure `body` never becomes a YAML frontmatter field.

### Phase 4: Input-form UI

Replace or wrap:

```text
lua/tasknotes/ui/task_form.lua
```

Add:

```text
lua/tasknotes/ui/form_fields.lua
lua/tasknotes/ui/form_validation.lua
```

Support:

```text
new task
edit task
body editing
select fields
date validation
CSV normalization
```

### Phase 5: Dependency cleanup

Make dependency checks conditional:

```text
input-form.nvim conditional
nui.nvim conditional
snacks.nvim conditional
bases.nvim required
```

### Phase 6: Public API cleanup

Expose:

```text
create_task
update_task
delete_task
get_task
get_task_by_id
get_task_by_path
```

Keep UI commands unchanged.

### Phase 7: Tests and docs

Add:

```text
docs/hooks.md
docs/form.md
tests/hooks_spec.lua
tests/task_identity_spec.lua
tests/body_update_spec.lua
```

---

## Final target architecture

```text
tasknotes.nvim
├── config.lua
├── hooks.lua
├── parser.lua
├── task_manager.lua
├── cache.lua
├── init.lua
├── ui/
│   ├── task_form.lua
│   ├── form_fields.lua
│   ├── form_validation.lua
│   ├── time_tracker.lua
├── snacks_picker.lua
└── docs/
    ├── hooks.md
    ├── form.md
```

TaskNotes should become:

```text
task lifecycle owner
task file owner
task metadata owner
task form owner
task cache owner
task event publisher
task callback host
```

The result is a fork that remains recognizable as `tasknotes.nvim`, but has a clean plugin-first architecture suitable for external integrations without timing hacks, buffer autocmd patching, or post-write file mutation.
