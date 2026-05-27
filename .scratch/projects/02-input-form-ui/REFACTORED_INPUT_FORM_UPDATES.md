# Refactored Input-Form Updates: TaskNotes Integration Guide

## Purpose

This guide covers the tasknotes.nvim changes needed to integrate with our personal fork of `input-form.nvim`. The fork adds per-field keymaps, focus tracking, per-field completion, actions, `on_focus`/`on_blur` callbacks, and field metadata — all features that the upstream library does not support.

This replaces the earlier `PHASE_4_IMPLEMENTATION_GUIDE.md` as the authoritative integration plan. The scope is the same (form UI + datepicker + conditional deps), but the implementation details reflect the actual fork API rather than a speculative one.

**Depends on:**

- Phase 1 (hooks + task identity) — completed
- Phase 3 (body-aware updates) — completed
- input-form.nvim fork — completed at `/home/andrew/Documents/Projects/input-form.nvim`

---

## Current State

### tasknotes.nvim

`ui/task_form.lua` is a 227-line NUI-based form. It renders plain text lines in a popup buffer and parses them back with regex. It has:

- No typed fields (everything is a text line)
- No select dropdowns for status/priority
- No multiline body field
- No field-level validation feedback
- No date picker
- No completion on any field
- A bug on line 27 (`task.title` instead of `task.priority`)

The dependency checks in `init.lua` (lines 18-66) hard-require `nui.nvim` and `snacks.nvim`. There is no `input-form.nvim` awareness.

The config `ui` block (lines 69-75) has no `form_backend`, `fallback_to_nui`, or `date_picker` options.

None of the helper modules exist yet: `form_fields.lua`, `form_validation.lua`, `date_picker.lua`.

### input-form.nvim fork

The fork provides a complete form library with these features relevant to our integration:

**Field types:** `text`, `multiline`, `select`, `checkbox`, `spacer`

**Per-field properties (new in fork):**

| Property | Type | Description |
|----------|------|-------------|
| `keymaps` | `table<string, function(form, field)>` | Keymaps active only when field is focused |
| `action` | `function(form, field)` | Fires on action key (default `<CR>`) |
| `on_focus` | `function(form, field)` | Fires when field gains focus |
| `on_blur` | `function(form, field)` | Fires when field loses focus |
| `complete` | `table` or `function(context)` | Completion source (static list or dynamic callback) |
| `complete_opts` | `table` | Options: `auto`, `min_chars`, `debounce_ms`, `separator` |
| `meta` | `table` | Opaque metadata accessible in all callbacks |
| `validator` | `function(value)` | Returns error string or nil |

**Form methods (new in fork):**

| Method | Description |
|--------|-------------|
| `form:get_focused_field()` | Returns currently focused field object or nil |
| `form:get_value(name)` | Get field value by name |
| `form:set_value(name, value)` | Set field value by name |
| `form:render()` | Re-render all fields |
| `form:show()` | Open the form |
| `form:close()` | Permanently tear down |
| `form:submit()` | Validate and call on_submit |

**Completion:** Triggered by `<C-Space>` (configurable). Uses `vim.fn.complete()` natively — no external completion plugin required. Supports `complete_opts.separator` for CSV-aware completion (e.g., tags field).

**Keymaps:** Per-field keymaps are buffer-local (each field is its own buffer/window), so they are automatically focus-gated. Field keymaps override global keymaps on conflict.

---

## Step 1: Add config options

**File:** `lua/tasknotes/config.lua` (lines 69-75)

**Current:**

```lua
ui = {
  border_style = "rounded",
  task_form_width = 60,
  task_form_height = 20,
  time_tracker_width = 50,
  time_tracker_height = 15,
},
```

**New:**

```lua
ui = {
  border_style = "rounded",
  task_form_width = 60,
  task_form_height = 20,
  time_tracker_width = 50,
  time_tracker_height = 15,

  form_backend = "input-form",
  fallback_to_nui = true,

  date_picker = {
    enabled = true,
    backend = "datepicker.nvim",
    fallback_backend = "text",
    format = "%Y-%m-%d",
    week_start = "monday",
    keymaps = {
      open = "<C-d>",
      clear = "<C-x>",
      today = "<C-t>",
    },
  },
},
```

---

## Step 2: Create `lua/tasknotes/ui/form_validation.lua`

**New file.** Pure validation and normalization functions. No UI dependencies.

```lua
local M = {}

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

  local normalized = os.date("%Y-%m-%d", os.time({
    year = year, month = month, day = day, hour = 12,
  }))

  if normalized ~= value then
    return false, field_name .. " is not a valid date"
  end

  return true
end

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

function M.normalize_optional_date(value)
  if value == nil or value == "" then
    return nil
  end
  return value
end

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

**New file.** Adapter for date selection. Shields form code from the datepicker backend.

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

**New file.** Builds `input-form.nvim` field specs and converts form results back to task data. This is where our fork's per-field keymaps, completion, and validators are wired in.

```lua
local M = {}

local config = require("tasknotes.config")
local validation = require("tasknotes.ui.form_validation")

--- Build per-field keymaps for date fields.
--- Uses the input-form.nvim fork's per-field keymap support.
--- Keymaps are only active when the date field is focused.
local function date_field_keymaps(field_name, title)
  local date_picker = require("tasknotes.ui.date_picker")
  local opts = config.get()
  local dp = opts.ui and opts.ui.date_picker or {}

  if dp.enabled == false then
    return nil
  end

  local maps = dp.keymaps or {}

  return {
    [maps.open or "<C-d>"] = function(form, field)
      local current = form:get_value(field.name)

      date_picker.pick_date({
        initial = current,
        title = title,
        on_select = function(date_string)
          form:set_value(field.name, date_string)
          form:render()
        end,
      })
    end,

    [maps.today or "<C-t>"] = function(form, field)
      form:set_value(field.name, date_picker.today())
      form:render()
    end,

    [maps.clear or "<C-x>"] = function(form, field)
      form:set_value(field.name, "")
      form:render()
    end,
  }
end

--- Build the input-form.nvim field specs for a task.
---
--- The fork's field spec supports: keymaps, action, on_focus, on_blur,
--- complete, complete_opts, meta, and validator — all per-field.
---
--- task: existing task table (empty table for new task)
--- form_opts: { mode = "create" | "edit" }
function M.create_task_fields(task, form_opts)
  task = task or {}
  form_opts = form_opts or {}
  local cfg = config.get()

  -- Build select options from config
  local status_options = vim.tbl_map(function(s)
    return { id = s.name, label = s.display }
  end, cfg.statuses)

  local priority_options = vim.tbl_map(function(p)
    return { id = p.name, label = p.display }
  end, cfg.priorities)

  -- Validator adapter: input-form expects function(value) -> error_string|nil
  local date_validator = function(field_name)
    return function(value)
      local ok, err = validation.validate_date(value, field_name)
      if not ok then return err end
    end
  end

  -- Build completion sources from existing tasks for CSV fields
  local context_items = M.collect_existing_values("contexts")
  local project_items = M.collect_existing_values("projects")
  local tag_items = M.collect_existing_values("tags")

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
      validator = date_validator("Due Date"),
      keymaps = date_field_keymaps("due", "Select due date"),
      meta = { field_type = "date", format = "YYYY-MM-DD" },
    },

    {
      name = "scheduled",
      label = "Scheduled Date",
      type = "text",
      default = task.scheduled or "",
      validator = date_validator("Scheduled Date"),
      keymaps = date_field_keymaps("scheduled", "Select scheduled date"),
      meta = { field_type = "date", format = "YYYY-MM-DD" },
    },

    { type = "spacer" },

    {
      name = "contexts",
      label = "Contexts",
      type = "text",
      default = type(task.contexts) == "table" and table.concat(task.contexts, ", ") or "",
      complete = #context_items > 0 and context_items or nil,
      complete_opts = { separator = ",", auto = true, min_chars = 1 },
    },

    {
      name = "projects",
      label = "Projects",
      type = "text",
      default = type(task.projects) == "table" and table.concat(task.projects, ", ") or "",
      complete = #project_items > 0 and project_items or nil,
      complete_opts = { separator = ",", auto = true, min_chars = 1 },
    },

    {
      name = "tags",
      label = "Tags",
      type = "text",
      default = type(task.tags) == "table" and table.concat(task.tags, ", ") or "",
      complete = #tag_items > 0 and tag_items or nil,
      complete_opts = { separator = ",", auto = true, min_chars = 1 },
    },

    {
      name = "blockedBy",
      label = "Blocked By",
      type = "text",
      default = type(task.blockedBy) == "table" and table.concat(task.blockedBy, ", ") or "",
      -- Future: add action to open a task picker for blockedBy selection
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

--- Collect unique values for a CSV field across all existing tasks.
--- Used to populate completion sources.
function M.collect_existing_values(field_name)
  local task_manager = require("tasknotes.task_manager")
  local seen = {}
  local items = {}

  for _, task in ipairs(task_manager.tasks or {}) do
    local values = task[field_name]
    if type(values) == "table" then
      for _, v in ipairs(values) do
        if type(v) == "string" and v ~= "" and not seen[v] then
          seen[v] = true
          table.insert(items, v)
        end
      end
    end
  end

  table.sort(items)
  return items
end

--- Convert input-form.nvim results into a task data table.
--- Returns data, body as two values (body goes through update_opts.body, not frontmatter).
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

**Key integration points with the input-form.nvim fork:**

- **`keymaps`** on date fields — uses the fork's per-field keymap support. The `function(form, field)` signature matches exactly. Keymaps are only active when the date field is focused because each field is its own buffer.
- **`complete`** on CSV fields — uses the fork's per-field completion. Static item lists populated from existing task data. `complete_opts.separator = ","` enables CSV-aware completion.
- **`validator`** on date and time estimate fields — uses the fork's per-field validation with inline error display.
- **`meta`** on date fields — marks them as date fields for any future focus-aware behavior.
- **`select` type** for status and priority — uses the fork's built-in dropdown instead of parsing text lines.
- **`multiline` type** for body — uses the fork's multiline input instead of no body support at all.

---

## Step 5: Rewrite `lua/tasknotes/ui/task_form.lua`

**Existing file — full rewrite.** Dual-backend: input-form.nvim (primary) with NUI fallback.

```lua
local M = {}

local config = require("tasknotes.config")
local task_manager = require("tasknotes.task_manager")
local hooks = require("tasknotes.hooks")

--- Resolve which form backend to use.
--- Returns "input-form" or "nui" or nil.
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

    vim.notify("Neither input-form.nvim nor nui.nvim available", vim.log.levels.ERROR)
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

-- ─────────────────────────────────────────────
-- input-form.nvim backend
-- ─────────────────────────────────────────────

local function emit_task_open(task)
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

local function new_task_input_form()
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
        vim.ui.select({ "Yes", "No" }, {
          prompt = "Open new task file?",
        }, function(choice)
          if choice == "Yes" then
            vim.cmd("edit " .. vim.fn.fnameescape(task.path))
            emit_task_open(task)
          end
        end)
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

  -- Parse the file to get the body (not stored in the task object cache)
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

      -- Use Phase 3 body-aware update API
      local success = task_manager.update_task(task.path, data, { body = body })

      if success then
        vim.notify("Task updated", vim.log.levels.INFO)

        local current_file = vim.api.nvim_buf_get_name(0)
        if current_file == task.path then
          vim.cmd("edit!")
        end
      end
    end,
  })

  form:show()
end

-- ─────────────────────────────────────────────
-- NUI fallback backend (preserved from original)
-- ─────────────────────────────────────────────

-- The NUI backend preserves the original task_form.lua behavior exactly.
-- It does NOT support body editing, select dropdowns, completion, or
-- date picker integration. It exists only as a degraded fallback for
-- users without input-form.nvim.

local function create_nui_form_fields(task)
  task = task or {}

  return {
    "TaskNotes Form",
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    "",
    "Title: " .. (task.title or ""),
    "",
    "Status: " .. (task.status or "open"),
    "",
    "Priority: " .. (task.priority or "none"),
    "",
    "Due Date (YYYY-MM-DD): " .. (task.due or ""),
    "",
    "Scheduled (YYYY-MM-DD): " .. (task.scheduled or ""),
    "",
    "Contexts (comma-separated): " .. table.concat(task.contexts or {}, ", "),
    "",
    "Projects (comma-separated): " .. table.concat(task.projects or {}, ", "),
    "",
    "Tags (comma-separated): " .. table.concat(task.tags or {}, ", "),
    "",
    "Blocked By (comma-separated file paths): " .. table.concat(task.blockedBy or {}, ", "),
    "",
    "Time Estimate (minutes): " .. (task.timeEstimate or ""),
    "",
    "",
    "[Press <C-s> to save, <Esc> to cancel]",
  }
end

local function parse_nui_form_data(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local data = {}

  for _, line in ipairs(lines) do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key and value then
      key = vim.trim(key)
      value = vim.trim(value)

      if key == "Title" then
        data.title = value
      elseif key == "Status" then
        data.status = value
      elseif key == "Priority" then
        data.priority = value
      elseif key:match("Due Date") then
        data.due = value ~= "" and value or nil
      elseif key:match("Scheduled") then
        data.scheduled = value ~= "" and value or nil
      elseif key:match("Contexts") then
        data.contexts = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Projects") then
        data.projects = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Tags") then
        data.tags = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Blocked By") then
        data.blockedBy = value ~= "" and vim.split(value, ",%s*") or {}
      elseif key:match("Time Estimate") then
        data.timeEstimate = value ~= "" and tonumber(value) or nil
      end
    end
  end

  return data
end

local function validate_nui_data(data)
  if not data.title or data.title == "" then
    return false, "Title is required"
  end

  if data.due and data.due ~= "" then
    if not data.due:match("^%d%d%d%d%-%d%d%-%d%d$") then
      return false, "Due date must be in YYYY-MM-DD format"
    end
  end

  if data.scheduled and data.scheduled ~= "" then
    if not data.scheduled:match("^%d%d%d%d%-%d%d%-%d%d$") then
      return false, "Scheduled date must be in YYYY-MM-DD format"
    end
  end

  return true
end

local function show_nui_form(task, on_save)
  local Popup = require("nui.popup")
  local event = require("nui.utils.autocmd").event
  local opts = config.get()
  local is_edit = task ~= nil

  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = opts.ui.border_style,
      text = {
        top = is_edit and " Edit Task " or " New Task ",
        top_align = "center",
      },
    },
    position = "50%",
    size = {
      width = opts.ui.task_form_width,
      height = opts.ui.task_form_height,
    },
    buf_options = {
      modifiable = true,
      readonly = false,
    },
  })

  local lines = create_nui_form_fields(task)
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(popup.bufnr, "filetype", "tasknotes-form")

  vim.keymap.set("n", "<C-s>", function()
    local data = parse_nui_form_data(popup.bufnr)
    local valid, err = validate_nui_data(data)
    if not valid then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    popup:unmount()
    if on_save then
      on_save(data)
    end
  end, { buffer = popup.bufnr, noremap = true })

  popup:on(event.BufLeave, function()
    popup:unmount()
  end)

  popup:mount()
end

local function new_task_nui()
  show_nui_form(nil, function(data)
    local task = task_manager.create_task(data)
    if task then
      vim.ui.select({ "Yes", "No" }, {
        prompt = "Open new task file?",
      }, function(choice)
        if choice == "Yes" then
          vim.cmd("edit " .. task.path)
          emit_task_open(task)
        end
      end)
    end
  end)
end

local function edit_task_nui(task)
  show_nui_form(task, function(data)
    local success = task_manager.update_task(task.path, data)
    if success then
      vim.notify("Task updated", vim.log.levels.INFO)
      local current_file = vim.api.nvim_buf_get_name(0)
      if current_file == task.path then
        vim.cmd("edit!")
      end
    end
  end)
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

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

**Changes from the original:**

- Removed the top-level `pcall(require, "nui.popup")` guard that made the entire module return empty if NUI was missing. Backend resolution now happens at call time.
- Fixed the priority bug (line 27 of original used `task.title` instead of `task.priority`).
- NUI fallback uses `vim.keymap.set` with `{ buffer = bufnr }` instead of `vim.map` (which doesn't exist in standard Neovim API — the original had a bug here).
- NUI `create_nui_form_fields` fixes the priority field to use `task.priority`.
- NUI backend is functionally identical to the original but properly encapsulated.
- input-form backend adds: select dropdowns, multiline body, date picker keymaps, CSV completion, per-field validation.

---

## Step 6: Make dependency checks conditional

**File:** `lua/tasknotes/init.lua` (lines 18-66)

Replace the current `check_dependencies()` function:

```lua
local function check_dependencies(user_config)
  local errors = {}
  local warnings = {}

  -- bases.nvim: always required
  local has_bases, bases = pcall(require, "bases")
  if not has_bases then
    table.insert(errors, "bases.nvim is required but not found")
  else
    local required_api = { "get_view", "list_views", "evaluate", "query" }
    for _, fn_name in ipairs(required_api) do
      if type(bases[fn_name]) ~= "function" then
        table.insert(errors, "bases.nvim missing function: " .. fn_name)
      end
    end
  end

  -- Preview merged config for conditional checks
  local defaults = require("tasknotes.config").defaults or {}
  local preview = vim.tbl_deep_extend("force", defaults, user_config or {})

  -- snacks.nvim: warning if missing (picker won't work)
  local has_snacks = pcall(require, "snacks")
  if not has_snacks then
    table.insert(warnings, "snacks.nvim not found — task picker will be unavailable")
  end

  -- Form backend checks
  local form_backend = preview.ui and preview.ui.form_backend or "input-form"
  local fallback_to_nui = preview.ui and preview.ui.fallback_to_nui

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
  elseif form_backend == "nui" then
    local has_nui = pcall(require, "nui.popup")
    if not has_nui then
      table.insert(warnings, "nui.nvim not found — task form will be unavailable")
    end
  end

  -- datepicker.nvim: optional warning
  local dp = preview.ui and preview.ui.date_picker
  if dp and dp.enabled ~= false and dp.backend == "datepicker.nvim" then
    local has_datepicker = pcall(require, "datepicker")
    if not has_datepicker then
      table.insert(warnings, "datepicker.nvim not found — date fields will use text input fallback")
    end
  end

  return errors, warnings
end
```

Update the `setup()` caller to use the new signature and emit warnings:

```lua
function M.setup(user_config)
  user_config = user_config or {}
  local errors, warnings = check_dependencies(user_config)

  if #errors > 0 then
    vim.notify("TaskNotes:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
    return
  end

  for _, w in ipairs(warnings) do
    vim.notify("TaskNotes: " .. w, vim.log.levels.WARN)
  end

  -- ... rest of setup unchanged ...
end
```

---

## Step 7: Simplify `init.lua` form callers

**File:** `lua/tasknotes/init.lua` (lines 216-235)

Remove the NUI availability checks. `task_form.lua` now handles backend resolution internally.

**Current:**

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
function M.new_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.new_task()
end

function M.edit_task()
  local task_form = require("tasknotes.ui.task_form")
  task_form.edit_current_buffer()
end
```

---

## Step 8: Add tests

### 8a. `tests/test_form_validation.lua`

Test pure validation and normalization (no UI needed):

```
validate_date accepts valid YYYY-MM-DD
validate_date accepts empty string
validate_date accepts nil
validate_date rejects invalid month (2026-99-01)
validate_date rejects impossible day (2026-02-31)
validate_date rejects non-date string
validate_time_estimate accepts positive integer
validate_time_estimate accepts empty string
validate_time_estimate rejects negative number
validate_time_estimate rejects decimal
validate_time_estimate rejects non-number string
normalize_csv splits comma-separated values
normalize_csv trims whitespace
normalize_csv returns empty table for empty string
normalize_csv returns empty table for nil
normalize_optional_date returns nil for empty string
normalize_optional_date returns nil for nil
normalize_optional_date passes through valid date
validate_task_data requires title
validate_task_data rejects invalid due date
validate_task_data accepts valid complete data
```

### 8b. `tests/test_date_picker.lua`

Test date picker helpers (no datepicker.nvim needed):

```
is_valid_date returns true for valid date
is_valid_date returns false for invalid month
is_valid_date returns false for impossible day (Feb 31)
is_valid_date returns false for non-date string
is_valid_date returns false for empty string
is_valid_date returns false for nil
today returns YYYY-MM-DD format
```

### 8c. `tests/test_form_fields.lua`

Test field construction and value normalization (needs child neovim for config):

```
create_task_fields returns expected field names
create_task_fields uses select type for status
create_task_fields uses select type for priority
create_task_fields uses multiline type for body
create_task_fields populates defaults from task object
create_task_fields date fields have keymaps when date_picker enabled
create_task_fields CSV fields have completion sources
form_values_to_task_data normalizes blank due to nil
form_values_to_task_data normalizes blank scheduled to nil
form_values_to_task_data splits CSV contexts
form_values_to_task_data splits CSV projects
form_values_to_task_data splits CSV tags
form_values_to_task_data converts timeEstimate to number
form_values_to_task_data returns body as second value
form_values_to_task_data body is not in returned data table
```

---

## Step 9: Add `docs/date-picker.md`

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

Floating calendar widget. Requires [Dzejkop/datepicker.nvim](https://github.com/Dzejkop/datepicker.nvim).

### text

Falls back to `vim.ui.input()` with date validation. Used automatically
when `datepicker.nvim` is not installed.

## Date Format

Dates are stored as `YYYY-MM-DD` in task frontmatter.
```

---

## Files Summary

| File | Action | Description |
|------|--------|-------------|
| `lua/tasknotes/config.lua` | Modify | Add `form_backend`, `fallback_to_nui`, `date_picker` to `ui` block |
| `lua/tasknotes/ui/form_validation.lua` | Create | Pure validation and normalization |
| `lua/tasknotes/ui/date_picker.lua` | Create | Datepicker adapter with text fallback |
| `lua/tasknotes/ui/form_fields.lua` | Create | Field construction with keymaps, completion, validators |
| `lua/tasknotes/ui/task_form.lua` | Rewrite | Dual-backend form (input-form + NUI fallback) |
| `lua/tasknotes/init.lua` | Modify | Conditional dep checks, simplify new_task/edit_task |
| `tests/test_form_validation.lua` | Create | Validation and normalization tests |
| `tests/test_date_picker.lua` | Create | Date helper tests |
| `tests/test_form_fields.lua` | Create | Field construction and normalization tests |
| `docs/date-picker.md` | Create | Date picker documentation |

**No changes to:** `hooks.lua`, `parser.lua`, `task_manager.lua`, `cache.lua`, `urgency.lua`, `commands.lua`, `snacks_picker.lua`, `time_tracker.lua`

---

## Implementation Order

1. **Config** (Step 1) — add UI options
2. **form_validation.lua** (Step 2) — pure functions, no deps
3. **date_picker.lua** (Step 3) — adapter module
4. **form_fields.lua** (Step 4) — field specs with fork features
5. **Tests for Steps 2-4** — validate helpers before touching UI
6. **task_form.lua** (Step 5) — the main rewrite
7. **Conditional deps** (Step 6) — update init.lua
8. **Simplify callers** (Step 7) — remove NUI guards
9. **Full tests** (Step 8) — all test files
10. **Docs** (Step 9) — date-picker.md
11. **Run full test suite** — `make test`

---

## Fork Features Used

This table maps each input-form.nvim fork feature to its use in tasknotes:

| Fork Feature | Used By | Purpose |
|-------------|---------|---------|
| `select` field type | status, priority fields | Dropdown selection instead of text parsing |
| `multiline` field type | body field | Markdown body editing in the form |
| `validator` | title, due, scheduled, timeEstimate | Inline error display on invalid input |
| `keymaps` (per-field) | due, scheduled date fields | `<C-d>` opens date picker, `<C-t>` inserts today, `<C-x>` clears |
| `complete` (per-field) | contexts, projects, tags fields | Auto-complete from existing task values |
| `complete_opts.separator` | contexts, projects, tags fields | CSV-aware completion (completes individual items in list) |
| `complete_opts.auto` | contexts, projects, tags fields | Trigger completion as user types |
| `meta` | date fields | Mark fields as date type for future extensibility |
| `get_value(name)` | date picker keymaps | Read current field value before opening picker |
| `set_value(name, value)` | date picker keymaps | Write selected date back to field |
| `render()` | date picker keymaps | Redraw form after programmatic value change |
| `get_focused_field()` | (available for future use) | Focus-aware behavior |
| `on_focus` / `on_blur` | (available for future use) | Focus tracking callbacks |
| `action` | (available for future use) | E.g., task picker for blockedBy field |
