# Phase 4 Implementation Guide: Input-Form UI + Datepicker

## Scope

Replace the NUI text-buffer task form with an `input-form.nvim` based form that supports typed fields (text, select, multiline), date picker integration, body editing, and validation. Keep the NUI form as a fallback.

**In scope:**

- Add `ui.form_backend`, `ui.fallback_to_nui`, and `ui.date_picker` config
- Create `lua/tasknotes/ui/form_fields.lua` — field construction and value normalization
- Create `lua/tasknotes/ui/form_validation.lua` — validation logic
- Create `lua/tasknotes/ui/date_picker.lua` — datepicker.nvim adapter with text fallback
- Rewrite `lua/tasknotes/ui/task_form.lua` — dual-backend form (input-form primary, NUI fallback)
- Make dependency checks conditional (nui, input-form, datepicker, snacks)
- Add tests for validation, field normalization, and date picker helpers
- Add `docs/date-picker.md`

**Not in scope:**

- Filename template system
- TaskNotesBackfillIds command

**Depends on:**

- Phase 1 (hooks + task identity) — completed
- Phase 3 (body-aware updates) — completed

---

## Current State

`ui/task_form.lua` is a 227-line NUI-based form. It renders plain text lines (`Title: value`) in a popup buffer and parses them back with regex. It has no select dropdowns, no multiline body field, no validation feedback, and no date picker.

`input-form.nvim` provides typed fields (text, select, multiline, checkbox), built-in validation with error display, Tab/Shift-Tab navigation, and `get_value`/`set_value`/`render` methods — everything the form needs.

The devenv already supports optional `input-form.nvim` loading via `TASKNOTES_INPUT_FORM_PATH` or a sibling checkout.

---

## Step 1: Add config options

**File:** `lua/tasknotes/config.lua`

Add three new keys to the `ui` block (after line 75, within the existing `ui = { ... }` table):

```lua
ui = {
  border_style = "rounded",
  task_form_width = 60,
  task_form_height = 20,
  time_tracker_width = 50,
  time_tracker_height = 15,

  -- NEW: form backend selection
  form_backend = "input-form",   -- "input-form" | "nui"
  fallback_to_nui = true,        -- fall back to NUI when input-form.nvim unavailable

  -- NEW: date picker config
  date_picker = {
    enabled = true,
    backend = "datepicker.nvim",    -- "datepicker.nvim" | "text"
    fallback_backend = "text",      -- used when preferred backend unavailable
    format = "%Y-%m-%d",
    week_start = "monday",          -- "monday" | "sunday"
    keymaps = {
      open = "<C-d>",
      clear = "<C-x>",
      today = "<C-t>",
    },
  },
},
```

**Key decisions:**

- `form_backend = "input-form"` is the default. Users who don't install `input-form.nvim` get the NUI fallback automatically.
- `date_picker.enabled = true` by default, but the picker only activates when `datepicker.nvim` is installed. Missing plugin falls back to `vim.ui.input()`.

---

## Step 2: Create `lua/tasknotes/ui/form_validation.lua`

**New file.** Owns all validation and normalization logic. No dependencies on UI libraries.

```lua
local M = {}

--- Validate a YYYY-MM-DD date string.
--- Empty/nil values are valid (field is optional).
function M.validate_date(value, field_name)
  field_name = field_name or "Date"

  if value == nil or value == "" then
    return true
  end

  if type(value) ~= "string" then
    return false, field_name .. " must be a string"
  end

  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false, field_name .. " must be in YYYY-MM-DD format"
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)

  if month < 1 or month > 12 or day < 1 or day > 31 then
    return false, field_name .. " is not a valid date"
  end

  -- Normalize through os.time to catch impossible dates (Feb 31, etc.)
  local normalized = os.date("%Y-%m-%d", os.time({
    year = year, month = month, day = day, hour = 12,
  }))

  if normalized ~= value then
    return false, field_name .. " is not a valid date"
  end

  return true
end

--- Validate time estimate (positive whole number of minutes).
function M.validate_time_estimate(value)
  if value == nil or value == "" then
    return true
  end

  local number = tonumber(value)
  if not number then
    return false, "Time estimate must be a number"
  end

  if number < 0 then
    return false, "Time estimate must be positive"
  end

  if math.floor(number) ~= number then
    return false, "Time estimate must be whole minutes"
  end

  return true
end

--- Split a comma-separated string into a trimmed list.
function M.normalize_csv(value)
  if value == nil or value == "" then
    return {}
  end

  local result = {}
  for item in tostring(value):gmatch("[^,]+") do
    item = vim.trim(item)
    if item ~= "" then
      table.insert(result, item)
    end
  end

  return result
end

--- Normalize empty date strings to nil (prevents empty strings in frontmatter).
function M.normalize_optional_date(value)
  if value == nil or value == "" then
    return nil
  end
  return value
end

--- Validate a complete task data table.
function M.validate_task_data(data)
  if not data.title or data.title == "" then
    return false, "Title is required"
  end

  local due_ok, due_err = M.validate_date(data.due, "Due Date")
  if not due_ok then
    return false, due_err
  end

  local sched_ok, sched_err = M.validate_date(data.scheduled, "Scheduled Date")
  if not sched_ok then
    return false, sched_err
  end

  local est_ok, est_err = M.validate_time_estimate(data.timeEstimate)
  if not est_ok then
    return false, est_err
  end

  return true
end

return M
```

---

## Step 3: Create `lua/tasknotes/ui/date_picker.lua`

**New file.** Adapter that shields form code from the datepicker backend. Provides `pick_date()`, `today()`, and `is_valid_date()`.

```lua
local M = {}

local config = require("tasknotes.config")

local function today()
  return os.date("%Y-%m-%d")
end

local function is_valid_ymd(value)
  if type(value) ~= "string" then
    return false
  end

  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return false
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)

  if not year or month < 1 or month > 12 or day < 1 or day > 31 then
    return false
  end

  local normalized = os.date("%Y-%m-%d", os.time({
    year = year, month = month, day = day, hour = 12,
  }))

  return normalized == value
end

local function normalize_initial(initial)
  if type(initial) == "string" and is_valid_ymd(initial) then
    return initial
  end
  return today()
end

function M.today()
  return today()
end

function M.is_valid_date(value)
  return is_valid_ymd(value)
end

--- Open a date picker using the configured backend.
---
--- opts:
---   initial    string|nil   current field value (YYYY-MM-DD)
---   title      string|nil   picker title
---   on_select  function     callback receiving YYYY-MM-DD string
---   backend    string|nil   override backend choice
function M.pick_date(opts)
  opts = opts or {}

  local tasknotes_opts = config.get()
  local dp = tasknotes_opts.ui and tasknotes_opts.ui.date_picker or {}

  if dp.enabled == false then
    return M.pick_with_text(opts)
  end

  local backend = opts.backend or dp.backend or "datepicker.nvim"

  if backend == "datepicker.nvim" then
    local ok = pcall(require, "datepicker")
    if ok then
      return M.pick_with_datepicker_nvim(opts)
    end

    if dp.fallback_backend == "text" then
      return M.pick_with_text(opts)
    end

    vim.notify("datepicker.nvim is not available", vim.log.levels.WARN)
    return
  end

  return M.pick_with_text(opts)
end

--- Backend: datepicker.nvim floating calendar.
function M.pick_with_datepicker_nvim(opts)
  local datepicker = require("datepicker")
  local tasknotes_opts = config.get()
  local dp = tasknotes_opts.ui and tasknotes_opts.ui.date_picker or {}

  datepicker.open({
    title = opts.title or "Select date",
    initial_date = normalize_initial(opts.initial),
    week_start = opts.week_start or dp.week_start or "monday",
    on_select = function(date)
      if not date or not date.iso then
        return
      end
      if opts.on_select then
        opts.on_select(date.iso)
      end
    end,
  })
end

--- Backend: vim.ui.input() text prompt.
function M.pick_with_text(opts)
  vim.ui.input({
    prompt = opts.title or "Date (YYYY-MM-DD): ",
    default = normalize_initial(opts.initial),
  }, function(value)
    if not value or value == "" then
      return
    end

    if not is_valid_ymd(value) then
      vim.notify("Invalid date. Expected YYYY-MM-DD.", vim.log.levels.ERROR)
      return
    end

    if opts.on_select then
      opts.on_select(value)
    end
  end)
end

return M
```

---

## Step 4: Create `lua/tasknotes/ui/form_fields.lua`

**New file.** Owns field construction for `input-form.nvim` and value normalization between form data and task data.

```lua
local M = {}

local config = require("tasknotes.config")
local validation = require("tasknotes.ui.form_validation")

--- Build date-field keymaps for input-form.nvim.
--- These let the user press <C-d> to open a picker, <C-t> for today, <C-x> to clear.
local function date_field_keymaps(field_name, title)
  local date_picker = require("tasknotes.ui.date_picker")
  local opts = config.get()
  local dp = opts.ui and opts.ui.date_picker or {}

  if dp.enabled == false then
    return nil
  end

  local maps = dp.keymaps or {}

  return {
    [maps.open or "<C-d>"] = function(form)
      local current = form:get_value(field_name)

      date_picker.pick_date({
        initial = current,
        title = title,
        on_select = function(date_string)
          form:set_value(field_name, date_string)
          form:render()
        end,
      })
    end,

    [maps.today or "<C-t>"] = function(form)
      form:set_value(field_name, date_picker.today())
      form:render()
    end,

    [maps.clear or "<C-x>"] = function(form)
      form:set_value(field_name, "")
      form:render()
    end,
  }
end

--- Build the input-form.nvim field spec for a task.
---
--- task: existing task table (empty table for new task)
--- opts: { mode = "create" | "edit" }
function M.create_task_fields(task, opts)
  task = task or {}
  opts = opts or {}
  local cfg = config.get()

  local status_options = vim.tbl_map(function(s)
    return { id = s.name, label = s.display }
  end, cfg.statuses)

  local priority_options = vim.tbl_map(function(p)
    return { id = p.name, label = p.display }
  end, cfg.priorities)

  local date_validator = function(field_name)
    return function(value)
      local ok, err = validation.validate_date(value, field_name)
      if not ok then return err end
    end
  end

  local fields = {
    {
      name = "title",
      label = "Title",
      type = "text",
      default = task.title or "",
      validator = function(value)
        if not value or value == "" then
          return "Title is required"
        end
      end,
    },

    {
      name = "status",
      label = "Status",
      type = "select",
      default = task.status or "open",
      options = status_options,
    },

    {
      name = "priority",
      label = "Priority",
      type = "select",
      default = task.priority or "none",
      options = priority_options,
    },

    {
      name = "due",
      label = "Due Date",
      type = "text",
      default = task.due or "",
      placeholder = "YYYY-MM-DD",
      validator = date_validator("Due Date"),
      keymaps = date_field_keymaps("due", "Select due date"),
    },

    {
      name = "scheduled",
      label = "Scheduled Date",
      type = "text",
      default = task.scheduled or "",
      placeholder = "YYYY-MM-DD",
      validator = date_validator("Scheduled Date"),
      keymaps = date_field_keymaps("scheduled", "Select scheduled date"),
    },

    { type = "spacer" },

    {
      name = "contexts",
      label = "Contexts",
      type = "text",
      default = type(task.contexts) == "table" and table.concat(task.contexts, ", ") or "",
    },

    {
      name = "projects",
      label = "Projects",
      type = "text",
      default = type(task.projects) == "table" and table.concat(task.projects, ", ") or "",
    },

    {
      name = "tags",
      label = "Tags",
      type = "text",
      default = type(task.tags) == "table" and table.concat(task.tags, ", ") or "",
    },

    {
      name = "blockedBy",
      label = "Blocked By",
      type = "text",
      default = type(task.blockedBy) == "table" and table.concat(task.blockedBy, ", ") or "",
    },

    {
      name = "timeEstimate",
      label = "Time Estimate (minutes)",
      type = "text",
      default = task.timeEstimate and tostring(task.timeEstimate) or "",
      validator = function(value)
        local ok, err = validation.validate_time_estimate(value)
        if not ok then return err end
      end,
    },

    { type = "spacer" },

    {
      name = "body",
      label = "Notes",
      type = "multiline",
      default = task.body or "",
      height = 6,
    },
  }

  return fields
end

--- Convert input-form.nvim results table into a task data table
--- suitable for task_manager.create_task or task_manager.update_task.
---
--- Returns task_data, body (body is separate so callers can pass it via update_opts).
function M.form_values_to_task_data(values)
  local data = {
    title = values.title,
    status = values.status or "open",
    priority = values.priority or "none",

    due = validation.normalize_optional_date(values.due),
    scheduled = validation.normalize_optional_date(values.scheduled),

    contexts = validation.normalize_csv(values.contexts),
    projects = validation.normalize_csv(values.projects),
    tags = validation.normalize_csv(values.tags),
    blockedBy = validation.normalize_csv(values.blockedBy),

    timeEstimate = values.timeEstimate ~= "" and tonumber(values.timeEstimate) or nil,
  }

  local body = values.body or ""

  return data, body
end

return M
```

**Key decisions:**

- `form_values_to_task_data` returns `data, body` as two values. This keeps `body` out of the updates table, matching the Phase 3 API where body goes through `update_opts.body`.
- Date field keymaps are `nil` when `date_picker.enabled = false`, so no keymaps are registered.
- Uses `default` (not `value`) to match input-form.nvim's API.

---

## Step 5: Rewrite `lua/tasknotes/ui/task_form.lua`

**Existing file — full rewrite.** The new version supports two backends: `input-form.nvim` (primary) and NUI (fallback).

The structure:

```lua
local M = {}

local config = require("tasknotes.config")
local task_manager = require("tasknotes.task_manager")
local hooks = require("tasknotes.hooks")

--- Resolve which form backend to use.
--- Returns "input-form" or "nui" or nil (with error notification).
local function resolve_backend()
  local opts = config.get()
  local backend = opts.ui and opts.ui.form_backend or "input-form"

  if backend == "input-form" then
    local ok = pcall(require, "input-form")
    if ok then
      return "input-form"
    end

    if opts.ui and opts.ui.fallback_to_nui ~= false then
      local nui_ok = pcall(require, "nui.popup")
      if nui_ok then
        return "nui"
      end
    end

    vim.notify("Neither input-form.nvim nor nui.nvim available for task form", vim.log.levels.ERROR)
    return nil
  end

  if backend == "nui" then
    local ok = pcall(require, "nui.popup")
    if ok then
      return "nui"
    end

    vim.notify("nui.nvim not available for task form", vim.log.levels.ERROR)
    return nil
  end

  vim.notify("Unknown form_backend: " .. tostring(backend), vim.log.levels.ERROR)
  return nil
end

--
-- input-form.nvim backend
--

local function new_task_input_form()
  -- require here to avoid load-time errors when plugin is missing
  local input_form = require("input-form")
  local form_fields = require("tasknotes.ui.form_fields")
  local validation = require("tasknotes.ui.form_validation")

  local fields = form_fields.create_task_fields({}, { mode = "create" })

  local form = input_form.create_form({
    title = "New Task",
    inputs = fields,

    on_submit = function(results)
      local data, body = form_fields.form_values_to_task_data(results)

      local ok, err = validation.validate_task_data(data)
      if not ok then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      data.body = body
      local task = task_manager.create_task(data)

      if task then
        vim.cmd("edit " .. vim.fn.fnameescape(task.path))

        hooks.run_callback("on_task_open", {
          operation = "open",
          task = task,
          path = task.path,
          opts = config.get(),
          metadata = { source = "create" },
        })
        hooks.emit(hooks.events.TASK_OPEN, {
          operation = "open",
          task = task,
          path = task.path,
          opts = config.get(),
          metadata = { source = "create" },
        })
      end
    end,
  })

  form:show()
end

local function edit_task_input_form(task)
  local input_form = require("input-form")
  local form_fields = require("tasknotes.ui.form_fields")
  local validation = require("tasknotes.ui.form_validation")
  local parser = require("tasknotes.parser")

  local parsed = parser.parse_file(task.path)
  if not parsed then
    vim.notify("Could not parse task file", vim.log.levels.ERROR)
    return
  end

  local task_with_body = vim.deepcopy(task)
  task_with_body.body = parsed.body or ""

  local fields = form_fields.create_task_fields(task_with_body, { mode = "edit" })

  local form = input_form.create_form({
    title = "Edit Task",
    inputs = fields,

    on_submit = function(results)
      local data, body = form_fields.form_values_to_task_data(results)

      local ok, err = validation.validate_task_data(data)
      if not ok then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      local success = task_manager.update_task(task.path, data, { body = body })

      if success then
        vim.notify("Task updated", vim.log.levels.INFO)

        -- Refresh buffer if the task file is currently open
        local current_file = vim.api.nvim_buf_get_name(0)
        if current_file == task.path then
          vim.cmd("edit!")
        end
      end
    end,
  })

  form:show()
end

--
-- NUI fallback backend (preserved from original task_form.lua)
--

local function create_nui_form_fields(task)
  -- ... existing create_form_fields logic (lines 15-48 of original) ...
end

local function parse_nui_form_data(bufnr)
  -- ... existing parse_form_data logic (lines 51-86 of original) ...
end

local function validate_nui_data(data)
  -- ... existing validate_data logic (lines 89-108 of original) ...
end

local function show_nui_form(task, on_save)
  -- ... existing show_form logic (lines 111-167 of original) ...
end

local function new_task_nui()
  -- ... existing new_task logic (lines 170-194 of original) ...
end

local function edit_task_nui(task)
  -- ... existing edit_task logic (lines 197-211 of original) ...
end

--
-- Public API — dispatches to the resolved backend
--

function M.new_task()
  local backend = resolve_backend()
  if not backend then return end

  if backend == "input-form" then
    new_task_input_form()
  else
    new_task_nui()
  end
end

function M.edit_task(task)
  local backend = resolve_backend()
  if not backend then return end

  if backend == "input-form" then
    edit_task_input_form(task)
  else
    edit_task_nui(task)
  end
end

function M.edit_current_buffer()
  local filepath = vim.api.nvim_buf_get_name(0)
  local task = task_manager.get_task_by_path(filepath)

  if not task then
    vim.notify("Current buffer is not a TaskNote", vim.log.levels.WARN)
    return
  end

  M.edit_task(task)
end

return M
```

**Key decisions:**

- The NUI fallback functions are **preserved as-is** from the original file. No changes to their behavior. They remain a reliable fallback for users without `input-form.nvim`.
- The `input-form` backend uses `form_fields.create_task_fields` and `form_fields.form_values_to_task_data` for clean separation.
- The edit flow reads body from the file via `parser.parse_file` and populates it into the form, then passes it through `update_opts.body` on save — using the Phase 3 API.
- `resolve_backend()` is called per-invocation, not at module load. This means installing `input-form.nvim` mid-session works without restart.
- TASK_OPEN hook is fired after creating a task (matching original behavior).

---

## Step 6: Make dependency checks conditional

**File:** `lua/tasknotes/init.lua` (lines 18-66)

The current `check_dependencies` function hard-requires `bases.nvim`, `nui.nvim`, and `snacks.nvim`. Refactor so only `bases.nvim` is hard-required.

**Current:**

```lua
local function check_dependencies()
  local missing = {}
  -- ... checks bases.nvim, nui.nvim, snacks.nvim as hard requirements ...
  -- ... checks plenary as optional ...
end
```

**New:**

```lua
local function check_dependencies(user_config)
  local errors = {}
  local warnings = {}

  -- bases.nvim: always required
  local has_bases = pcall(require, "bases")
  if not has_bases then
    table.insert(errors, "bases.nvim is required but not found")
  else
    -- validate bases API (existing checks)
    local bases = require("bases")
    local required_fns = { "get_view", "list_views", "evaluate", "query" }
    for _, fn_name in ipairs(required_fns) do
      if type(bases[fn_name]) ~= "function" then
        table.insert(errors, "bases.nvim missing function: " .. fn_name)
      end
    end
  end

  -- Preview the merged config to check conditional deps
  local preview = vim.tbl_deep_extend("force", config.get() or {}, user_config or {})

  -- snacks.nvim: required only if picker is used (default: yes)
  local picker_enabled = not preview.picker or preview.picker.enabled ~= false
  if picker_enabled then
    local has_snacks = pcall(require, "snacks")
    if not has_snacks then
      table.insert(warnings, "snacks.nvim not found — task picker will be unavailable")
    end
  end

  -- nui.nvim: required only if NUI form or time tracker is used
  local form_backend = preview.ui and preview.ui.form_backend or "input-form"
  local fallback_to_nui = preview.ui and preview.ui.fallback_to_nui
  local needs_nui = form_backend == "nui" or fallback_to_nui ~= false
  if needs_nui then
    local has_nui = pcall(require, "nui.popup")
    if not has_nui then
      if form_backend == "nui" then
        table.insert(warnings, "nui.nvim not found — task form will be unavailable")
      end
      -- If fallback_to_nui but nui missing, that's fine — just means no fallback
    end
  end

  -- input-form.nvim: check if preferred backend is available
  if form_backend == "input-form" then
    local has_input_form = pcall(require, "input-form")
    if not has_input_form then
      local has_nui = pcall(require, "nui.popup")
      if fallback_to_nui ~= false and has_nui then
        table.insert(warnings, "input-form.nvim not found — falling back to NUI form")
      elseif fallback_to_nui == false then
        table.insert(warnings, "input-form.nvim not found and NUI fallback disabled — task form unavailable")
      else
        table.insert(warnings, "input-form.nvim not found — install it or nui.nvim for task forms")
      end
    end
  end

  -- datepicker.nvim: optional, warning only
  local dp = preview.ui and preview.ui.date_picker
  if dp and dp.enabled ~= false and dp.backend == "datepicker.nvim" then
    local has_datepicker = pcall(require, "datepicker")
    if not has_datepicker then
      table.insert(warnings, "datepicker.nvim not found — date fields will use text input fallback")
    end
  end

  -- plenary: optional
  local has_plenary = pcall(require, "plenary")
  if not has_plenary then
    -- silent, truly optional
  end

  return errors, warnings
end
```

Update the caller in `setup()` to use the new signature and handle warnings:

```lua
function M.setup(user_config)
  local errors, warnings = check_dependencies(user_config)

  if #errors > 0 then
    vim.notify("TaskNotes: " .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    return
  end

  for _, w in ipairs(warnings) do
    vim.notify("TaskNotes: " .. w, vim.log.levels.WARN)
  end

  -- ... rest of setup unchanged ...
end
```

**Key decisions:**

- `bases.nvim` remains the only hard error. Everything else is a warning.
- `snacks.nvim` missing is a warning, not a blocker — the plugin can still create/edit tasks without a picker.
- `nui.nvim` missing is only a problem if it's the active form backend or time tracker is used.
- Warnings fire once at setup time so users know what's degraded.

---

## Step 7: Update `init.lua` form-calling code

**File:** `lua/tasknotes/init.lua`

The existing `new_task()` and `edit_task()` check for NUI availability before calling `task_form`. Since `task_form.lua` now handles backend resolution internally, simplify these:

**Current `new_task` (lines 216-224):**

```lua
function M.new_task()
  local has_nui = pcall(require, "nui.popup")
  if has_nui then
    local task_form = require("tasknotes.ui.task_form")
    task_form.new_task()
  else
    vim.notify("NUI not available - cannot create task form", vim.log.levels.ERROR)
  end
end
```

**New:**

```lua
function M.new_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.new_task()
end
```

**Current `edit_task` (lines 227-235):**

```lua
function M.edit_task()
  local has_nui = pcall(require, "nui.popup")
  if has_nui then
    local task_form = require("tasknotes.ui.task_form")
    task_form.edit_current_buffer()
  else
    vim.notify("NUI not available - cannot create task form", vim.log.levels.ERROR)
  end
end
```

**New:**

```lua
function M.edit_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.edit_current_buffer()
end
```

Backend resolution is now `task_form`'s responsibility via `resolve_backend()`.

---

## Step 8: Add tests

### 8a. `tests/test_form_validation.lua`

Test the pure validation and normalization functions (no UI dependencies):

```
validate_date accepts valid YYYY-MM-DD
validate_date accepts empty string (optional)
validate_date accepts nil (optional)
validate_date rejects invalid month (2026-99-01)
validate_date rejects impossible day (2026-02-31)
validate_date rejects non-date string
validate_time_estimate accepts positive integer
validate_time_estimate accepts empty string
validate_time_estimate rejects negative number
validate_time_estimate rejects decimal
validate_time_estimate rejects non-number
normalize_csv splits comma-separated values
normalize_csv trims whitespace
normalize_csv returns empty table for empty string
normalize_csv returns empty table for nil
normalize_optional_date returns nil for empty string
normalize_optional_date returns nil for nil
normalize_optional_date returns value for valid date
validate_task_data requires title
validate_task_data rejects invalid due date
validate_task_data accepts valid complete data
```

These tests are pure Lua — no child Neovim process needed for most of them. Use the existing mini.test pattern but the tests themselves call the module functions directly.

### 8b. `tests/test_date_picker.lua`

Test the date picker helpers (no datepicker.nvim dependency needed):

```
date_picker.is_valid_date("2026-06-01") returns true
date_picker.is_valid_date("2026-99-01") returns false
date_picker.is_valid_date("2026-02-31") returns false
date_picker.is_valid_date("not-a-date") returns false
date_picker.is_valid_date("") returns false
date_picker.is_valid_date(nil) returns false
date_picker.today() returns YYYY-MM-DD format
```

### 8c. `tests/test_form_fields.lua`

Test field construction and value normalization:

```
create_task_fields returns expected field names
create_task_fields populates defaults from task object
create_task_fields date fields have keymaps when date_picker enabled
form_values_to_task_data normalizes blank due to nil
form_values_to_task_data normalizes blank scheduled to nil
form_values_to_task_data splits CSV contexts
form_values_to_task_data splits CSV projects
form_values_to_task_data splits CSV tags
form_values_to_task_data converts timeEstimate to number
form_values_to_task_data returns body as second value
```

---

## Step 9: Add `docs/date-picker.md`

**New file:**

```markdown
# Date Picker

TaskNotes supports calendar-based date selection for `due` and `scheduled`
fields when using the `input-form.nvim` form backend.

## Keymaps

When focused on a date field:

| Key | Action |
|-----|--------|
| `<C-d>` | Open date picker |
| `<C-t>` | Set today's date |
| `<C-x>` | Clear date |

Manual date input (`YYYY-MM-DD`) is always supported.

## Configuration

```lua
require("tasknotes").setup({
  ui = {
    form_backend = "input-form",
    date_picker = {
      enabled = true,
      backend = "datepicker.nvim",
      fallback_backend = "text",
      week_start = "monday",
      keymaps = {
        open = "<C-d>",
        clear = "<C-x>",
        today = "<C-t>",
      },
    },
  },
})
```

## Backends

### datepicker.nvim (recommended)

Floating calendar widget. Install [Dzejkop/datepicker.nvim](https://github.com/Dzejkop/datepicker.nvim):

```lua
{
  "Dzejkop/datepicker.nvim",
  dependencies = { "folke/snacks.nvim" },
}
```

### text

Falls back to `vim.ui.input()` with date validation. Used automatically
when `datepicker.nvim` is not installed.

## Date Format

TaskNotes stores dates as `YYYY-MM-DD` in task frontmatter.
```

---

## Files Summary

| File | Action | Description |
|------|--------|-------------|
| `lua/tasknotes/config.lua` | Modify | Add `form_backend`, `fallback_to_nui`, `date_picker` to `ui` block |
| `lua/tasknotes/ui/form_validation.lua` | Create | Validation and normalization (no UI deps) |
| `lua/tasknotes/ui/date_picker.lua` | Create | Datepicker adapter with text fallback |
| `lua/tasknotes/ui/form_fields.lua` | Create | Field construction for input-form.nvim |
| `lua/tasknotes/ui/task_form.lua` | Rewrite | Dual-backend form (input-form + NUI fallback) |
| `lua/tasknotes/init.lua` | Modify | Conditional dep checks, simplify new_task/edit_task |
| `tests/test_form_validation.lua` | Create | Validation/normalization tests |
| `tests/test_date_picker.lua` | Create | Date helper tests |
| `tests/test_form_fields.lua` | Create | Field construction/normalization tests |
| `docs/date-picker.md` | Create | Date picker documentation |

**No changes to:** `hooks.lua`, `parser.lua`, `task_manager.lua`, `cache.lua`, `urgency.lua`, `commands.lua`, `snacks_picker.lua`, `time_tracker.lua`

---

## Implementation Order

1. **Config** (Step 1) — add new UI options, no behavior change
2. **form_validation.lua** (Step 2) — pure functions, testable immediately
3. **date_picker.lua** (Step 3) — adapter, testable without datepicker.nvim
4. **form_fields.lua** (Step 4) — field construction, depends on Steps 2-3
5. **Run tests for Steps 2-4** — validate all helpers before touching UI
6. **task_form.lua** (Step 5) — the main rewrite, depends on Steps 2-4
7. **Conditional deps** (Step 6) — update init.lua check_dependencies
8. **Simplify init.lua callers** (Step 7) — remove NUI guards from new_task/edit_task
9. **Tests** (Step 8) — full test files for validation, date picker, form fields
10. **Docs** (Step 9) — date-picker.md
11. **Run full test suite** — `make test`

---

## Integration Contract

After this phase, the task form supports:

```lua
-- Automatic backend selection
require("tasknotes").setup({
  ui = {
    form_backend = "input-form",  -- default
    fallback_to_nui = true,       -- default
  },
})

-- Force NUI (for users who prefer it)
require("tasknotes").setup({
  ui = {
    form_backend = "nui",
  },
})

-- Disable date picker
require("tasknotes").setup({
  ui = {
    date_picker = {
      enabled = false,
    },
  },
})
```

The form collects body text via the multiline field and saves it through the Phase 3 body-aware update API. Date fields support picker integration or manual text entry. All existing commands (`:TaskNotesNew`, `:TaskNotesEdit`) work unchanged.

---

## Adapter Boundaries

```
task_form.lua
  ├── input-form backend
  │     ├── form_fields.lua     (field specs + value normalization)
  │     ├── form_validation.lua (pure validation)
  │     └── date_picker.lua     (date selection adapter)
  │           ├── datepicker.nvim backend
  │           └── vim.ui.input fallback
  └── NUI fallback backend
        └── (original task_form.lua logic, preserved as-is)
```

Each adapter boundary (`task_form → backend`, `date_picker → backend`) resolves at call time via `pcall(require, ...)`. No module fails to load because a plugin is missing.
