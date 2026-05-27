# Phase 3 Implementation Guide: Body-Aware Updates

## Scope

Add an `opts` parameter to `task_manager.update_task` so callers can explicitly pass a new body alongside frontmatter updates. This is the prerequisite for Phase 4 (input-form UI with body editing).

**In scope:**

- Extend `update_task` signature to `update_task(filepath, updates, update_opts)`
- Support `update_opts.body` to replace the task body on write
- Forward `update_opts` through the public API in `init.lua`
- Ensure hooks receive the final body (whether passed or preserved from file)
- Ensure body is never written into YAML frontmatter
- Add tests for body-aware update behavior

**Not in scope:**

- UI changes (form fields, input-form.nvim)
- Filename template system
- Dependency check refactoring

---

## Current State

`update_task(filepath, updates)` takes two arguments. It parses the existing file, captures `parsed.body`, and passes it through to `parser.write_file()`. The body is **preserved** but cannot be **replaced** by callers.

The hook context already has `ctx.body` (populated from `parsed.body`), and `parser.write_file` already accepts a body parameter. The wiring is 90% there — we just need to let callers override the body.

### Current call sites for `update_task`:

| Caller | File:Line | Passes body? |
|--------|-----------|-------------|
| `task_form.edit_task` | `ui/task_form.lua:199` | No — `task_manager.update_task(task.path, data)` |
| `snacks_picker` mark done | `snacks_picker.lua:108` | No — `task_manager.update_task(filepath, updates)` |
| `snacks_picker` edit action | `snacks_picker.lua:135` | No — `task_manager.update_task(filepath, updates)` |
| `init.lua` public API | `init.lua:462` | No — `task_manager.update_task(task.path, updates)` |
| `init.lua` toggle_timer | `init.lua:283` | No — `task_manager.update_task(filepath, updates)` |
| `time_tracker` | `ui/time_tracker.lua` (various) | No |

All existing call sites pass only two arguments. Adding an optional third argument is fully backwards-compatible.

---

## Step 1: Extend `update_task` signature

**File:** `lua/tasknotes/task_manager.lua` (line 640)

**Current:**

```lua
function M.update_task(filepath, updates)
```

**New:**

```lua
function M.update_task(filepath, updates, update_opts)
  update_opts = update_opts or {}
```

This is backwards-compatible — all existing callers pass two arguments, so `update_opts` defaults to `{}`.

---

## Step 2: Use `update_opts.body` when building the hook context

**File:** `lua/tasknotes/task_manager.lua` (lines 650-661)

**Current:**

```lua
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
```

**New:**

```lua
  local ctx = {
    operation = "update",
    task = old_task,
    old_task = old_task and vim.deepcopy(old_task) or nil,
    path = filepath,
    updates = updates,
    frontmatter = parsed.frontmatter,
    body = update_opts.body ~= nil and update_opts.body or parsed.body,
    opts = opts,
    metadata = {},
  }
```

**Why `~= nil` instead of just `or`?** Because `update_opts.body = ""` is a valid value (clearing the body). Using `or` would fall through to `parsed.body` when the caller explicitly passes an empty string.

The rest of the function already uses `ctx.body` for `parser.write_file` (line 689) and `create_task_object` (line 695). No further changes needed in the write path.

---

## Step 3: Ensure `body` key in `updates` does not leak into frontmatter

**File:** `lua/tasknotes/task_manager.lua` (lines 680-683)

**Current:**

```lua
  -- Update frontmatter fields
  for key, value in pairs(updates) do
    local fm_key = fm[key] or key
    ctx.frontmatter[fm_key] = value
  end
```

This loop writes every key from `updates` into frontmatter. If a caller accidentally puts `body` in the `updates` table (instead of in `update_opts.body`), it would be written as a YAML frontmatter field.

**New:**

```lua
  -- Update frontmatter fields (body is never a frontmatter field)
  for key, value in pairs(updates) do
    if key ~= "body" then
      local fm_key = fm[key] or key
      ctx.frontmatter[fm_key] = value
    end
  end
```

This is a safety guard. The canonical way to update body is via `update_opts.body`, but this prevents accidental frontmatter pollution.

---

## Step 4: Update the public API in `init.lua`

**File:** `lua/tasknotes/init.lua` (lines 459-463)

**Current:**

```lua
function M.update_task(ref, updates)
  local task = task_manager.resolve_task(ref)
  if not task then vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR); return false end
  return task_manager.update_task(task.path, updates)
end
```

**New:**

```lua
function M.update_task(ref, updates, update_opts)
  local task = task_manager.resolve_task(ref)
  if not task then vim.notify("Task not found: " .. tostring(ref), vim.log.levels.ERROR); return false end
  return task_manager.update_task(task.path, updates, update_opts)
end
```

This forwards `update_opts` (including `body`) from the public API to the internal function.

---

## Step 5: Verify hook context body behavior

No code changes needed here. Verify that the existing hook flow works correctly:

1. `before_task_update` callback receives `ctx.body` — which is now either the caller-provided body or the file's existing body.
2. Callbacks can mutate `ctx.body` (this already works — `ctx.body` is what gets written).
3. `after_task_update` callback receives `ctx.task` which has the final body via `create_task_object`.

The hook contract from Phase 1 already handles this correctly because the write path uses `ctx.body`, not `parsed.body` directly. The only change is how `ctx.body` is initially populated (Step 2).

---

## Step 6: Add tests

**File:** `tests/test_body_update.lua` (new file)

Follow the existing mini.test pattern from `tests/test_hooks.lua`.

### Test cases:

```
update_task preserves body when update_opts not provided
update_task preserves body when update_opts is empty
update_task replaces body when update_opts.body is provided
update_task accepts empty string body (clears body)
update_task does not write body key into frontmatter
update_task body is available in before_task_update ctx
update_task body mutation in before_task_update callback is respected
after_task_update ctx.task.body reflects the final body
```

### Implementation pattern:

```lua
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require("tests.helpers")

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      -- Create temp vault with a task file that has a body
    end,
    post_once = child.stop,
  },
})
```

### 6a. Body preservation (no update_opts)

```
Create a task file with body "Original body"
Call update_task(filepath, { status = "done" })
Parse the file
Assert body == "Original body"
Assert frontmatter.status == "done"
```

### 6b. Body replacement

```
Create a task file with body "Original body"
Call update_task(filepath, { status = "done" }, { body = "New body" })
Parse the file
Assert body == "New body"
Assert frontmatter.status == "done"
```

### 6c. Body cleared to empty string

```
Create a task file with body "Original body"
Call update_task(filepath, {}, { body = "" })
Parse the file
Assert body == ""
```

### 6d. Body not in frontmatter

```
Create a task file
Call update_task(filepath, { body = "sneaky" }, {})
Parse the file
Assert frontmatter.body == nil
Assert body from parsed file does not contain "sneaky" as a frontmatter field
```

### 6e. Hook receives body

```
Register before_task_update callback that records ctx.body
Create a task file with body "Original body"
Call update_task(filepath, {}, { body = "Hook body" })
Assert recorded ctx.body == "Hook body"
```

### 6f. Hook can mutate body

```
Register before_task_update callback that sets ctx.body = "Mutated by hook"
Create a task file with body "Original body"
Call update_task(filepath, {}, { body = "Caller body" })
Parse the file
Assert body == "Mutated by hook"
```

---

## Step 7: Run existing tests

After implementing Steps 1-5, run the full test suite:

```bash
make test
```

All existing tests must pass unchanged. The signature change is backwards-compatible, so no existing call sites or tests need modification.

---

## Files Modified

| File | Changes |
|------|---------|
| `lua/tasknotes/task_manager.lua` | Add `update_opts` param, use `update_opts.body`, guard `body` key in frontmatter loop |
| `lua/tasknotes/init.lua` | Forward `update_opts` in public `update_task` |
| `tests/test_body_update.lua` | New — body preservation, replacement, hook interaction tests |

**No changes to:** `hooks.lua`, `config.lua`, `parser.lua`, `cache.lua`, `ui/task_form.lua`, `snacks_picker.lua`

---

## Implementation Order

1. **Add `update_opts` parameter to `task_manager.update_task`** — Steps 1-3
2. **Run existing tests** — verify nothing broke
3. **Update public API in `init.lua`** — Step 4
4. **Write body update tests** — Step 6
5. **Run full test suite** — Step 7

---

## API Contract After This Phase

### Internal API

```lua
-- Frontmatter-only update (existing behavior, unchanged)
task_manager.update_task(filepath, { status = "done" })

-- Frontmatter + body update
task_manager.update_task(filepath, { status = "done" }, { body = "New notes" })

-- Body-only update
task_manager.update_task(filepath, {}, { body = "New notes" })

-- Clear body
task_manager.update_task(filepath, {}, { body = "" })
```

### Public API

```lua
-- By path or ID
require("tasknotes").update_task("/path/to/task.md", { status = "done" }, { body = "New notes" })
require("tasknotes").update_task("task-20260526-my-task", { status = "done" }, { body = "New notes" })
```

### Hook context

```lua
callbacks = {
  before_task_update = function(ctx)
    -- ctx.body is the body that will be written:
    --   update_opts.body if provided, otherwise parsed from file
    -- Mutating ctx.body changes what gets written
    ctx.body = ctx.body .. "\n\nAppended by hook"
  end,
}
```

---

## Relationship to Phase 4

Phase 4 (input-form UI) will use this API as follows:

```lua
-- In the new task_form.lua edit flow:
function M.edit_task(task)
  -- ... show form with body field ...

  on_submit = function(values)
    local body = values.body
    values.body = nil  -- Don't put body in updates

    task_manager.update_task(task.path, values, { body = body })
  end
end
```

The body-aware update API is the bridge between the form UI (which collects body text) and the task manager (which writes files). Without this phase, Phase 4 would have no way to save body edits through the standard update pipeline.
