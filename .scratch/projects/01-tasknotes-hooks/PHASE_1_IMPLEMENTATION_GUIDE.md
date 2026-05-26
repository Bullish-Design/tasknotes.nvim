# Phase 1 Implementation Guide: Hooks & Task Identity

## Scope

This phase wires the existing `hooks.lua` and `callbacks` config into the task lifecycle, and adds stable task IDs so upstream plugins can reference tasks by identity rather than file path.

**In scope:**

- Instrument `create_task`, `update_task`, `delete_task`, `refresh_task`, `scan_vault` with hook calls
- Emit `User` autocmds at each lifecycle point
- Add `TASK_OPEN` events at task-opening call sites
- Emit `SETUP_POST` at end of `setup()`
- Add `id` to field mapping, task objects, and cache lookups
- Add `tasks_by_id` index and `resolve_task()` for upstream consumers
- Expose public API functions on `init.lua` for programmatic CRUD
- Add tests for hook firing, cancellation, and task ID generation

**Not in scope:**

- UI changes (input-form.nvim, form refactoring)
- Filename template system
- Dependency check refactoring
- Body-aware update API (deferred to Phase 3 — hooks land first, body-aware updates build on top)

---

## Current State

`hooks.lua` exists with the correct event table, `emit()`, and `run_callback()`. The `callbacks` block exists in `config.lua` defaults. **Neither is imported or called anywhere.** This phase is purely about wiring.

---

## Step 1: Instrument `task_manager.create_task`

**File:** `lua/tasknotes/task_manager.lua`

**What to do:**

Add `local hooks = require("tasknotes.hooks")` at the top of the file (after the existing requires on line 6).

Then wrap the existing `create_task` flow. The current function (lines 457-511) does:

```
generate filename → check exists → build frontmatter → validate deps → write file → create object → cache → notify
```

Insert hook calls around the write:

```lua
function M.create_task(task_data)
  local opts = config.get()
  local fm = opts.field_mapping

  -- Generate filename from title
  local filename = task_data.title:gsub("%s+", "-"):gsub("[^%w%-]", ""):lower() .. ".md"
  local filepath = opts.vault_path .. "/" .. filename

  -- Check if file already exists
  if vim.fn.filereadable(filepath) == 1 then
    vim.notify("Task file already exists: " .. filename, vim.log.levels.ERROR)
    return nil
  end

  -- Build frontmatter
  local frontmatter = {}
  frontmatter[fm.title] = task_data.title
  frontmatter[fm.status] = task_data.status or "open"
  frontmatter[fm.priority] = task_data.priority or "none"
  frontmatter[fm.due] = task_data.due
  frontmatter[fm.scheduled] = task_data.scheduled
  frontmatter[fm.contexts] = task_data.contexts or {}
  frontmatter[fm.projects] = task_data.projects or {}
  frontmatter[fm.tags] = task_data.tags or { opts.task_tag }
  frontmatter[fm.timeEstimate] = task_data.timeEstimate
  frontmatter[fm.blockedBy] = task_data.blockedBy or {}
  frontmatter[fm.dateCreated] = os.date("!%Y-%m-%dT%H:%M:%SZ")
  frontmatter[fm.dateModified] = frontmatter[fm.dateCreated]

  -- Generate stable task ID
  if fm.id then
    frontmatter[fm.id] = task_data.id or M.generate_task_id(task_data.title)
  end

  -- Validate dependencies if provided
  if task_data.blockedBy and #task_data.blockedBy > 0 then
    local temp_task = { path = filepath, blockedBy = task_data.blockedBy }
    local valid, err = M.validate_dependencies(temp_task)
    if not valid then
      vim.notify("Invalid dependencies: " .. err, vim.log.levels.ERROR)
      return nil
    end
  end

  -- >>> HOOK: before_task_create <<<
  local ctx = {
    operation = "create",
    task_data = task_data,
    frontmatter = frontmatter,
    body = task_data.body or "",
    path = filepath,
    opts = opts,
    metadata = {},
  }

  local ret = hooks.run_callback("before_task_create", ctx)
  if ret == false or ctx.cancel then
    vim.notify(ctx.error or "Task creation cancelled", vim.log.levels.WARN)
    return nil
  end

  -- Apply any mutations the callback made to ctx
  frontmatter = ctx.frontmatter
  filepath = ctx.path

  -- Write file
  local success, err = parser.write_file(filepath, frontmatter, ctx.body)
  if not success then
    vim.notify(err, vim.log.levels.ERROR)
    return nil
  end

  -- Add to cache
  local task = M.create_task_object(filepath, frontmatter, ctx.body)
  table.insert(M.tasks, task)
  M.tasks_by_path[filepath] = task

  -- Update ID index
  if task.id then
    M.tasks_by_id[task.id] = task
  end

  -- Update persistent cache
  update_cache_file(filepath, task)

  -- >>> HOOK: after_task_create <<<
  ctx.task = task
  hooks.run_callback("after_task_create", ctx)
  hooks.emit(hooks.events.TASK_CREATE_POST, ctx)

  vim.notify("Created task: " .. filename, vim.log.levels.INFO)
  return task
end
```

**Key decisions:**

- The `before_task_create` callback fires **after** frontmatter is built but **before** file write. This lets consumers mutate `ctx.frontmatter` (e.g., add custom fields) or set `ctx.cancel = true`.
- The callback can also mutate `ctx.path` to override the file location.
- The `TASK_CREATE_POST` autocmd fires only on success — never after cancellation.
- No `TASK_CREATE_PRE` autocmd. The callback is the mutation surface; autocmds are for observation. Pre-write observation without mutation ability is confusing, so we skip it.

---

## Step 2: Instrument `task_manager.update_task`

**File:** `lua/tasknotes/task_manager.lua` (lines 546-598)

Same pattern:

```lua
function M.update_task(filepath, updates)
  local parsed = parser.parse_file(filepath)
  if not parsed then
    vim.notify("Could not read task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  local opts = config.get()
  local fm = opts.field_mapping
  local old_task = M.get_task_by_path(filepath)

  -- >>> HOOK: before_task_update <<<
  local ctx = {
    operation = "update",
    task = old_task,
    old_task = old_task and vim.deepcopy(old_task) or nil,
    path = filepath,
    updates = updates,
    frontmatter = parsed.frontmatter,
    body = parsed.body,
    opts = opts,
    metadata = {},
  }

  local ret = hooks.run_callback("before_task_update", ctx)
  if ret == false or ctx.cancel then
    vim.notify(ctx.error or "Task update cancelled", vim.log.levels.WARN)
    return false
  end

  -- Apply callback mutations
  updates = ctx.updates

  -- Validate dependencies if being updated
  if updates.blockedBy then
    local temp_task = { path = filepath, blockedBy = updates.blockedBy }
    local valid, err = M.validate_dependencies(temp_task)
    if not valid then
      vim.notify("Invalid dependencies: " .. err, vim.log.levels.ERROR)
      return false
    end
  end

  -- Update frontmatter fields
  for key, value in pairs(updates) do
    local fm_key = fm[key] or key
    ctx.frontmatter[fm_key] = value
  end

  -- Update modification date
  ctx.frontmatter[fm.dateModified] = os.date("!%Y-%m-%dT%H:%M:%SZ")

  -- Write back to file
  local success, err = parser.write_file(filepath, ctx.frontmatter, ctx.body)
  if not success then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  -- Update in-memory cache
  local task = M.create_task_object(filepath, ctx.frontmatter, ctx.body)
  M.tasks_by_path[filepath] = task

  -- Update in tasks array
  for i, t in ipairs(M.tasks) do
    if t.path == filepath then
      M.tasks[i] = task
      break
    end
  end

  -- Update ID index
  if task.id then
    M.tasks_by_id[task.id] = task
  end

  -- Update persistent cache
  update_cache_file(filepath, task)

  -- >>> HOOK: after_task_update <<<
  ctx.task = task
  hooks.run_callback("after_task_update", ctx)
  hooks.emit(hooks.events.TASK_UPDATE_POST, ctx)

  return true
end
```

**Key decisions:**

- `ctx.old_task` is a deep copy so callbacks can compare old vs new state.
- Callbacks can mutate `ctx.updates` to add/remove/change fields before they're applied.
- Dependency validation runs **after** the callback, so callback-injected `blockedBy` changes are validated too.

---

## Step 3: Instrument `task_manager.delete_task`

**File:** `lua/tasknotes/task_manager.lua` (lines 601-623)

```lua
function M.delete_task(filepath)
  local task = M.get_task_by_path(filepath)

  -- >>> HOOK: before_task_delete <<<
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

  -- Remove file
  local success = os.remove(filepath)
  if not success then
    vim.notify("Could not delete task file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  -- Remove from in-memory cache
  M.tasks_by_path[filepath] = nil
  for i, t in ipairs(M.tasks) do
    if t.path == filepath then
      table.remove(M.tasks, i)
      break
    end
  end

  -- Remove from ID index
  if task and task.id then
    M.tasks_by_id[task.id] = nil
  end

  -- Remove from persistent cache
  update_cache_file(filepath, nil)

  -- >>> HOOK: after_task_delete <<<
  hooks.run_callback("after_task_delete", ctx)
  hooks.emit(hooks.events.TASK_DELETE_POST, ctx)

  vim.notify("Deleted task", vim.log.levels.INFO)
  return true
end
```

---

## Step 4: Instrument `task_manager.scan_vault`

**File:** `lua/tasknotes/task_manager.lua` (lines 81-267)

At the **end** of `scan_vault`, after urgency recalculation and `M.is_loaded = true`, add:

```lua
  -- >>> HOOK: after_scan <<<
  local scan_ctx = {
    operation = "scan",
    tasks = M.tasks,
    task_count = #M.tasks,
    opts = opts,
    metadata = {
      force_validate = force_validate or false,
    },
  }
  hooks.run_callback("after_scan", scan_ctx)
  hooks.emit(hooks.events.TASK_SCAN_POST, scan_ctx)
```

**Important:** This must fire at **both** exit points of `scan_vault` — after the fast-path early return (line 152) and after the slow-path end (line 266). The cleanest approach is to extract the hook emission into a local function:

```lua
local function emit_scan_complete(opts, force_validate)
  local ctx = {
    operation = "scan",
    tasks = M.tasks,
    task_count = #M.tasks,
    opts = opts,
    metadata = {
      force_validate = force_validate or false,
    },
  }
  hooks.run_callback("after_scan", ctx)
  hooks.emit(hooks.events.TASK_SCAN_POST, ctx)
end
```

Then call `emit_scan_complete(opts, force_validate)` before each return.

---

## Step 5: Instrument `task_manager.refresh_task`

**File:** `lua/tasknotes/task_manager.lua` (lines 626-657)

At the end of `refresh_task`, after the cache update, add:

```lua
  -- >>> HOOK: after_refresh <<<
  local ctx = {
    operation = "refresh",
    task = task,
    path = filepath,
    opts = config.get(),
    metadata = {},
  }
  hooks.run_callback("after_refresh", ctx)
  hooks.emit(hooks.events.TASK_REFRESH_POST, ctx)

  return true
```

Also update the ID index when refreshing:

```lua
  if task.id then
    M.tasks_by_id[task.id] = task
  end
```

---

## Step 6: Instrument `setup()` in `init.lua`

**File:** `lua/tasknotes/init.lua` (line 161, just before `vim.notify("TaskNotes loaded")`)

```lua
  -- >>> HOOK: after_setup <<<
  local hooks = require("tasknotes.hooks")
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

---

## Step 7: Add `TASK_OPEN` events

There are three places where tasks are opened:

### 7a. Snacks picker confirm action

**File:** `lua/tasknotes/snacks_picker.lua` (line 166)

After `vim.cmd("edit " .. item.file)`:

```lua
  local hooks = require("tasknotes.hooks")
  local task = require("tasknotes.task_manager").get_task_by_path(item.file)
  if task then
    local ctx = {
      operation = "open",
      task = task,
      path = item.file,
      opts = require("tasknotes.config").get(),
      metadata = {},
    }
    hooks.run_callback("on_task_open", ctx)
    hooks.emit(hooks.events.TASK_OPEN, ctx)
  end
```

### 7b. Task form new_task "Open new task file?" flow

**File:** `lua/tasknotes/ui/task_form.lua` (line 179)

After `vim.cmd("edit " .. task.path)`:

```lua
  local hooks = require("tasknotes.hooks")
  local ctx = {
    operation = "open",
    task = task,
    path = task.path,
    opts = require("tasknotes.config").get(),
    metadata = { source = "create" },
  }
  hooks.run_callback("on_task_open", ctx)
  hooks.emit(hooks.events.TASK_OPEN, ctx)
```

### 7c. Dependency navigation (`goto_blocking_tasks`, `goto_blocked_tasks`)

**File:** `lua/tasknotes/init.lua`

These use `vim.cmd("edit " .. path)` in multiple places. Add the same pattern after each `vim.cmd("edit ...")` call. There are 4 call sites in `goto_blocking_tasks` (line 385, via select callback line 399) and `goto_blocked_tasks` (line 423, via select callback line 437).

**Recommendation:** Extract a helper to avoid repetition:

```lua
-- In init.lua, near the top (after requires)
local function open_task_file(filepath)
  vim.cmd("edit " .. filepath)
  local hooks = require("tasknotes.hooks")
  local task = task_manager.get_task_by_path(filepath)
  if task then
    hooks.run_callback("on_task_open", {
      operation = "open",
      task = task,
      path = filepath,
      opts = config.get(),
      metadata = {},
    })
    hooks.emit(hooks.events.TASK_OPEN, {
      operation = "open",
      task = task,
      path = filepath,
      opts = config.get(),
      metadata = {},
    })
  end
end
```

Then replace all `vim.cmd("edit " .. path)` calls in `init.lua` with `open_task_file(path)`.

---

## Step 8: Add task ID generation and lookup

### 8a. Add `id` to field mapping

**File:** `lua/tasknotes/config.lua` (line 29)

Add `id = "id"` as the first entry in `field_mapping`:

```lua
field_mapping = {
  id = "id",
  title = "title",
  ...
}
```

### 8b. Add `tasks_by_id` index

**File:** `lua/tasknotes/task_manager.lua` (line 10)

```lua
M.tasks_by_id = {}
```

### 8c. Add `generate_task_id`

**File:** `lua/tasknotes/task_manager.lua` (after the existing helpers, before `scan_vault`)

```lua
function M.generate_task_id(title)
  local slug = (title or "task")
    :lower()
    :gsub("%s+", "-")
    :gsub("[^%w%-]", "")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")

  -- Truncate slug to keep IDs reasonable
  if #slug > 40 then
    slug = slug:sub(1, 40):gsub("%-$", "")
  end

  return "task-" .. os.date("!%Y%m%d%H%M%S") .. "-" .. slug
end
```

### 8d. Extract `id` in `create_task_object`

**File:** `lua/tasknotes/task_manager.lua` (line 275, inside the task table constructor)

Add after the `path` field:

```lua
  local task = {
    path = filepath,
    id = normalize_value(frontmatter[fm.id], nil),
    title = normalize_value(frontmatter[fm.title], ""),
    ...
  }
```

### 8e. Populate `tasks_by_id` during `scan_vault`

Every place that inserts into `M.tasks_by_path` must also insert into `M.tasks_by_id`. There are several locations:

1. **Fast-path cache load** (line 126): After `M.tasks_by_path[filepath] = task`, add:
   ```lua
   if task.id then M.tasks_by_id[task.id] = task end
   ```

2. **Slow-path scan** (line 207): Same pattern after `M.tasks_by_path[filepath] = task`.

3. **Background validation** (`validate_cache_async`, line 710): Same pattern.

4. **`refresh_task`** (line 637): Same pattern.

Also clear `M.tasks_by_id` at the top of `scan_vault` alongside the other resets:

```lua
M.tasks = {}
M.tasks_by_path = {}
M.tasks_by_id = {}
```

### 8f. Add lookup and resolver functions

**File:** `lua/tasknotes/task_manager.lua` (after `get_task_by_path`)

```lua
function M.get_task_by_id(id)
  return M.tasks_by_id[id]
end

function M.resolve_task(ref)
  if not ref then
    return nil
  end

  -- Try path lookup first
  if M.tasks_by_path[ref] then
    return M.tasks_by_path[ref]
  end

  -- Try ID lookup
  if M.tasks_by_id[ref] then
    return M.tasks_by_id[ref]
  end

  return nil
end
```

### 8g. ID generation in `create_task`

Already shown in Step 1. The key line is:

```lua
if fm.id then
  frontmatter[fm.id] = task_data.id or M.generate_task_id(task_data.title)
end
```

This lets upstream plugins pass an explicit `id` in `task_data`, or auto-generate one.

---

## Step 9: Expose public API on `init.lua`

**File:** `lua/tasknotes/init.lua` (before `return M`, around line 442)

Add programmatic CRUD APIs that upstream plugins can call:

```lua
-- Programmatic task CRUD (for upstream plugins)

function M.create_task_programmatic(task_data)
  return task_manager.create_task(task_data)
end

function M.update_task(ref, updates)
  local task = task_manager.resolve_task(ref)
  if not task then
    vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR)
    return false
  end
  return task_manager.update_task(task.path, updates)
end

function M.delete_task(ref)
  local task = task_manager.resolve_task(ref)
  if not task then
    vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR)
    return false
  end
  return task_manager.delete_task(task.path)
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

function M.get_all_tasks(filter)
  return task_manager.get_tasks(filter)
end
```

**Note:** The existing `M.new_task()` and `M.edit_task()` are UI-facing and remain unchanged. The new functions are integration-facing and accept data directly.

---

## Step 10: Update `clear_cache` to reset ID index

**File:** `lua/tasknotes/task_manager.lua` (line 930)

In `clear_cache()`, add `M.tasks_by_id = {}` alongside the existing resets:

```lua
M.tasks = {}
M.tasks_by_path = {}
M.tasks_by_id = {}
M.is_loaded = false
```

---

## Step 11: Tests

**File:** `tests/test_hooks.lua` (new file)

Test categories:

### 11a. Callback firing

```
before_task_create callback receives correct ctx shape
after_task_create callback receives task object
before_task_update callback receives old_task and updates
after_task_update callback receives updated task
before_task_delete callback receives task
after_task_delete callback fires after deletion
after_scan callback receives task count
after_refresh callback receives refreshed task
```

### 11b. Cancellation

```
before_task_create returning false cancels creation (no file written)
before_task_create setting ctx.cancel cancels creation
before_task_update returning false cancels update (file unchanged)
before_task_delete returning false cancels deletion (file still exists)
cancelled create returns nil
cancelled update returns false
cancelled delete returns false
```

### 11c. Mutation

```
before_task_create can add custom frontmatter fields
before_task_create can modify path
before_task_update can modify updates table
before_task_update can add fields to updates
```

**File:** `tests/test_task_identity.lua` (new file)

```
generate_task_id produces consistent format
generate_task_id slugifies title
generate_task_id truncates long titles
create_task generates id when fm.id is configured
create_task uses provided id when given
tasks_by_id is populated during scan
get_task_by_id returns correct task
resolve_task works with path
resolve_task works with id
resolve_task returns nil for unknown ref
```

### Test implementation pattern

Follow the existing mini.test pattern from `tests/test_task_manager.lua`:

```lua
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      local temp_vault = child.lua_get([[vim.fn.tempname()]])
      child.lua(string.format([[
        vim.fn.mkdir('%s', 'p')
        Config = require('tasknotes.config')
        Config.setup({
          vault_path = '%s',
          callbacks = {
            before_task_create = function(ctx)
              -- test-specific callback
              _G.hook_called = true
              _G.hook_ctx = ctx
            end,
          },
        })
        TaskManager = require('tasknotes.task_manager')
      ]], temp_vault, temp_vault))
    end,
    post_once = child.stop,
  },
})
```

For callback testing, register callbacks via config that set global flags, then assert on those flags after the operation.

For cancellation testing:

```lua
Config.setup({
  vault_path = '%s',
  callbacks = {
    before_task_create = function(ctx)
      ctx.cancel = true
      ctx.error = "Test cancellation"
    end,
  },
})
```

Then assert that `create_task` returns `nil` and no file was written.

---

## Step 12: Add `after_setup` callback to config defaults

**File:** `lua/tasknotes/config.lua` (line 153)

Add `after_setup = nil` to the callbacks block:

```lua
callbacks = {
  after_setup = nil,

  before_task_create = nil,
  after_task_create = nil,
  ...
}
```

---

## Implementation Order

Do these in order, testing each step before moving to the next:

1. **Add `id` to field mapping** (config.lua) — trivial, no behavior change
2. **Add `tasks_by_id`, `generate_task_id`, `get_task_by_id`, `resolve_task`** (task_manager.lua) — pure additions
3. **Add `id` extraction to `create_task_object`** — reads from frontmatter, no write-side changes yet
4. **Populate `tasks_by_id` in scan paths** — index is now live
5. **Run existing tests** — verify nothing broke
6. **Instrument `create_task` with hooks + ID generation** — first behavioral change
7. **Instrument `update_task` with hooks**
8. **Instrument `delete_task` with hooks**
9. **Instrument `scan_vault` and `refresh_task` with hooks**
10. **Instrument `setup()` with `SETUP_POST`**
11. **Add `TASK_OPEN` events** at open call sites
12. **Add public API to `init.lua`**
13. **Write tests** (hooks + task identity)
14. **Run full test suite** — `make test`

---

## Files Modified

| File | Changes |
|---|---|
| `lua/tasknotes/config.lua` | Add `id` to `field_mapping`, `after_setup` to `callbacks` |
| `lua/tasknotes/task_manager.lua` | Add hooks require, `tasks_by_id`, ID generation, instrument all CRUD + scan + refresh |
| `lua/tasknotes/init.lua` | Add `SETUP_POST` hook, `open_task_file` helper, public API functions, `TASK_OPEN` at nav call sites |
| `lua/tasknotes/snacks_picker.lua` | Add `TASK_OPEN` after confirm action |
| `lua/tasknotes/ui/task_form.lua` | Add `TASK_OPEN` after opening new task |
| `tests/test_hooks.lua` | New — callback firing, cancellation, mutation tests |
| `tests/test_task_identity.lua` | New — ID generation, lookup, resolve tests |

**No changes to:** `hooks.lua` (already correct), `parser.lua`, `cache.lua`, `urgency.lua`, `commands.lua`

---

## Hook Contract for Upstream Plugins

After this phase, an upstream plugin can:

```lua
-- Register callbacks at setup time
require("tasknotes").setup({
  callbacks = {
    before_task_create = function(ctx)
      -- Add custom frontmatter
      ctx.frontmatter.my_field = "value"
    end,

    after_task_create = function(ctx)
      -- Sync to external system
      my_sync.push(ctx.task)
    end,

    before_task_update = function(ctx)
      -- Validate or transform updates
      if ctx.updates.status == "done" then
        ctx.updates.completedDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
      end
    end,
  },
})

-- Or listen via autocmd (non-mutating)
vim.api.nvim_create_autocmd("User", {
  pattern = "TaskNotesTaskCreatePost",
  callback = function(ev)
    local task = ev.data and ev.data.task
    if task then
      -- React to task creation
    end
  end,
})

-- Look up tasks by ID
local task = require("tasknotes").get_task("task-20260526120000-my-task")
local task = require("tasknotes").get_task("/path/to/my-task.md")  -- also works

-- Programmatic CRUD
require("tasknotes").update_task("task-20260526120000-my-task", { status = "done" })
require("tasknotes").delete_task("task-20260526120000-my-task")
```
