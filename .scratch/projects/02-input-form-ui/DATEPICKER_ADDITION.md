# DATEPICKER_ADDITION.md

# Adding Datepicker Functionality to the tasknotes.nvim Fork

## Purpose

This guide extends the previously proposed `tasknotes.nvim` fork refactor by adding calendar-based date selection to the improved `input-form.nvim` task form.

The goal is to make date entry faster for task fields such as:

- `due`
- `scheduled`

The user should still be able to type dates manually, but the form should also support opening a floating date picker and writing the selected date back into the active form field.

Recommended backend:

```text
Dzejkop/datepicker.nvim
```

Repository:

```text
https://github.com/Dzejkop/datepicker.nvim
```

Why this backend:

- It exposes a direct `require("datepicker").open(opts)` API.
- It supports `initial_date`.
- It confirms with `<CR>`.
- It returns the selected date through an `on_select` callback.
- Its callback payload includes `iso`, already formatted as `YYYY-MM-DD`.
- It uses `snacks.nvim`, which TaskNotes already expects for picker functionality.

TaskNotes should still wrap it behind its own adapter so the form does not depend directly on one date picker plugin.

---

## 1. Target User Experience

Inside the TaskNotes task form:

```text
Due Date:        [2026-06-01]
Scheduled Date:  [2026-05-28]
```

When the cursor is focused on either date field:

```text
<C-d> opens the date picker
<C-t> fills today's date
<C-x> clears the field
```

The user can also keep typing dates manually:

```text
2026-06-01
```

Validation remains unchanged:

```text
YYYY-MM-DD
```

The date picker is an accelerator, not a replacement for text input.

---

## 2. New Files

Add:

```text
lua/tasknotes/ui/date_picker.lua
```

Optionally add tests:

```text
tests/date_picker_spec.lua
tests/form_date_fields_spec.lua
```

Optionally add docs:

```text
docs/date-picker.md
```

---

## 3. Config Additions

Update `lua/tasknotes/config.lua`.

Add this under the existing `ui` config:

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

    -- Preferred backend.
    -- Supported values:
    --   "datepicker.nvim"
    --   "text"
    backend = "datepicker.nvim",

    -- Used when the preferred backend is unavailable.
    fallback_backend = "text",

    -- Output format for task frontmatter.
    -- Keep this aligned with existing TaskNotes date validation.
    format = "%Y-%m-%d",

    -- Datepicker display behavior.
    week_start = "monday", -- "monday" | "sunday"

    -- Form-field keymaps.
    keymaps = {
      open = "<C-d>",
      clear = "<C-x>",
      today = "<C-t>",
    },
  },
}
```

Recommended final default:

```lua
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
}
```

---

## 4. Dependency Handling

`datepicker.nvim` should be optional, not hard-required.

TaskNotes should behave as follows:

| Condition | Behavior |
|---|---|
| `ui.date_picker.enabled = false` | Date fields are plain text fields |
| `backend = "datepicker.nvim"` and plugin exists | Use floating date picker |
| `backend = "datepicker.nvim"` and plugin missing | Use fallback backend |
| `fallback_backend = "text"` | Use `vim.ui.input()` |
| no backend available | Keep manual text editing and notify only when picker is invoked |

Do not fail `tasknotes.setup()` just because `datepicker.nvim` is unavailable.

---

## 5. Update Dependency Checks

In `lua/tasknotes/init.lua`, update the dependency check logic.

The existing fork refactor should already make dependency checks conditional. Add `datepicker.nvim` as an optional backend check.

Example helper:

```lua
local function check_datepicker_dependency(opts, warnings)
  local dp = opts.ui and opts.ui.date_picker
  if not dp or not dp.enabled then
    return
  end

  if dp.backend ~= "datepicker.nvim" then
    return
  end

  local has_datepicker = pcall(require, "datepicker")
  if not has_datepicker then
    table.insert(
      warnings,
      "datepicker.nvim not found - date fields will fall back to text input"
    )
  end
end
```

Recommended placement:

```lua
local function check_dependencies(user_config)
  local errors = {}
  local warnings = {}

  -- Existing checks:
  -- bases.nvim
  -- snacks.nvim conditionally
  -- nui.nvim conditionally
  -- input-form.nvim conditionally
  -- plenary.nvim optional

  local preview_opts = vim.tbl_deep_extend("force", defaults, user_config or {})
  check_datepicker_dependency(preview_opts, warnings)

  return errors, warnings
end
```

Important: this should produce a warning only. It should not block setup.

---

## 6. Implement `lua/tasknotes/ui/date_picker.lua`

Create:

```text
lua/tasknotes/ui/date_picker.lua
```

Implementation:

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

  if not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return false
  end

  local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)

  if not year or not month or not day then
    return false
  end

  if month < 1 or month > 12 then
    return false
  end

  if day < 1 or day > 31 then
    return false
  end

  local normalized = os.date("%Y-%m-%d", os.time({
    year = year,
    month = month,
    day = day,
    hour = 12,
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

    vim.notify(
      "datepicker.nvim is not available",
      vim.log.levels.WARN
    )
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
    prompt = opts.title or "Date YYYY-MM-DD: ",
    default = normalize_initial(opts.initial),
  }, function(value)
    if not value or value == "" then
      return
    end

    if not is_valid_ymd(value) then
      vim.notify(
        "Invalid date. Expected YYYY-MM-DD.",
        vim.log.levels.ERROR
      )
      return
    end

    if opts.on_select then
      opts.on_select(value)
    end
  end)
end

return M
```

Notes:

- `datepicker.nvim` already returns an `iso` field.
- TaskNotes should consume only the string `YYYY-MM-DD`.
- The adapter shields form code from backend-specific callback payloads.
- `normalize_initial()` avoids opening the date picker with invalid field content.

---

## 7. Integrate With `input-form.nvim` Date Fields

The exact integration depends on the API shape of your `input-form.nvim` form builder. The TaskNotes form should define `due` and `scheduled` as enhanced text fields.

Conceptually:

```lua
{
  name = "due",
  label = "Due Date",
  type = "text",
  value = task.due or "",
  placeholder = "YYYY-MM-DD",
  validate = function(value)
    return validation.validate_date(value, "Due Date")
  end,
  keymaps = date_keymaps("due", "Select due date"),
}
```

And:

```lua
{
  name = "scheduled",
  label = "Scheduled Date",
  type = "text",
  value = task.scheduled or "",
  placeholder = "YYYY-MM-DD",
  validate = function(value)
    return validation.validate_date(value, "Scheduled Date")
  end,
  keymaps = date_keymaps("scheduled", "Select scheduled date"),
}
```

Add helper in `lua/tasknotes/ui/form_fields.lua`:

```lua
local date_picker = require("tasknotes.ui.date_picker")
local config = require("tasknotes.config")

local function date_field_keymaps(field_name, title)
  local opts = config.get()
  local dp = opts.ui and opts.ui.date_picker or {}
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
```

If `input-form.nvim` uses a different callback signature, adapt the `form:get_value`, `form:set_value`, and `form:render()` calls to the actual API. The important contract is:

```text
focused date field + open keymap
  -> read current value
  -> open picker
  -> receive YYYY-MM-DD
  -> write selected value back to same field
  -> redraw form
```

---

## 8. Add Date Field Helpers to `form_fields.lua`

Update `lua/tasknotes/ui/form_fields.lua`.

Example structure:

```lua
local M = {}

local config = require("tasknotes.config")
local validation = require("tasknotes.ui.form_validation")
local date_picker = require("tasknotes.ui.date_picker")

local function date_field_keymaps(field_name, title)
  local opts = config.get()
  local dp = opts.ui and opts.ui.date_picker or {}
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

function M.create_task_fields(task, opts)
  task = task or {}
  opts = opts or {}

  return {
    {
      name = "title",
      label = "Title",
      type = "text",
      value = task.title or "",
      required = true,
    },

    {
      name = "status",
      label = "Status",
      type = "select",
      value = task.status or "open",
      options = vim.tbl_map(function(status)
        return status.name
      end, config.get().statuses),
    },

    {
      name = "priority",
      label = "Priority",
      type = "select",
      value = task.priority or "none",
      options = vim.tbl_map(function(priority)
        return priority.name
      end, config.get().priorities),
    },

    {
      name = "due",
      label = "Due Date",
      type = "text",
      value = task.due or "",
      placeholder = "YYYY-MM-DD",
      validate = function(value)
        return validation.validate_date(value, "Due Date")
      end,
      keymaps = date_field_keymaps("due", "Select due date"),
    },

    {
      name = "scheduled",
      label = "Scheduled Date",
      type = "text",
      value = task.scheduled or "",
      placeholder = "YYYY-MM-DD",
      validate = function(value)
        return validation.validate_date(value, "Scheduled Date")
      end,
      keymaps = date_field_keymaps("scheduled", "Select scheduled date"),
    },

    {
      name = "contexts",
      label = "Contexts",
      type = "text",
      value = table.concat(task.contexts or {}, ", "),
    },

    {
      name = "projects",
      label = "Projects",
      type = "text",
      value = table.concat(task.projects or {}, ", "),
    },

    {
      name = "tags",
      label = "Tags",
      type = "text",
      value = table.concat(task.tags or {}, ", "),
    },

    {
      name = "blockedBy",
      label = "Blocked By",
      type = "text",
      value = table.concat(task.blockedBy or {}, ", "),
    },

    {
      name = "timeEstimate",
      label = "Time Estimate",
      type = "text",
      value = task.timeEstimate and tostring(task.timeEstimate) or "",
      validate = validation.validate_time_estimate,
    },

    {
      name = "body",
      label = "Body",
      type = "multiline",
      filetype = "markdown",
      value = task.body or "",
    },
  }
end

return M
```

This keeps the date behavior local to the field definitions.

---

## 9. Update `form_validation.lua`

Update or add:

```text
lua/tasknotes/ui/form_validation.lua
```

Implementation:

```lua
local M = {}

local date_picker = require("tasknotes.ui.date_picker")

function M.validate_date(value, field_name)
  field_name = field_name or "Date"

  if value == nil or value == "" then
    return true
  end

  if not date_picker.is_valid_date(value) then
    return false, field_name .. " must be in YYYY-MM-DD format"
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

  local scheduled_ok, scheduled_err = M.validate_date(data.scheduled, "Scheduled Date")
  if not scheduled_ok then
    return false, scheduled_err
  end

  local estimate_ok, estimate_err = M.validate_time_estimate(data.timeEstimate)
  if not estimate_ok then
    return false, estimate_err
  end

  return true
end

return M
```

---

## 10. Normalize Form Output

In `lua/tasknotes/ui/form_fields.lua`, keep the conversion from form values to task data explicit.

```lua
function M.form_values_to_task_data(values)
  local validation = require("tasknotes.ui.form_validation")

  return {
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

    body = values.body or "",
  }
end
```

Important:

```text
due = ""        -> nil
scheduled = ""  -> nil
```

This prevents empty strings from being written into frontmatter unless that is desired.

---

## 11. Update `task_form.lua`

Wherever the form is constructed, switch from raw field definitions to `form_fields.create_task_fields()`.

Conceptual example:

```lua
local M = {}

local form_fields = require("tasknotes.ui.form_fields")
local validation = require("tasknotes.ui.form_validation")
local task_manager = require("tasknotes.task_manager")

function M.new_task(opts)
  opts = opts or {}

  local fields = form_fields.create_task_fields({}, {
    mode = "create",
  })

  require("input-form").open({
    title = "New Task",
    fields = fields,

    on_submit = function(values)
      local data = form_fields.form_values_to_task_data(values)

      local ok, err = validation.validate_task_data(data)
      if not ok then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      local task = task_manager.create_task(data)

      if task and opts.open_after_create ~= false then
        vim.cmd.edit(vim.fn.fnameescape(task.path))
      end
    end,
  })
end

function M.edit_task(task)
  local parser = require("tasknotes.parser")
  local parsed = parser.parse_file(task.path)

  if not parsed then
    vim.notify("Could not parse task file", vim.log.levels.ERROR)
    return
  end

  local task_with_body = vim.deepcopy(task)
  task_with_body.body = parsed.body or ""

  local fields = form_fields.create_task_fields(task_with_body, {
    mode = "edit",
  })

  require("input-form").open({
    title = "Edit Task",
    fields = fields,

    on_submit = function(values)
      local data = form_fields.form_values_to_task_data(values)

      local body = data.body
      data.body = nil

      local ok, err = validation.validate_task_data(data)
      if not ok then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      local success = task_manager.update_task(task.path, data, {
        body = body,
      })

      if success then
        vim.notify("Task updated", vim.log.levels.INFO)

        if vim.api.nvim_buf_get_name(0) == task.path then
          vim.cmd("edit!")
        end
      end
    end,
  })
end

return M
```

Adapt the `input-form.nvim` invocation to the actual API used in your fork. The datepicker requirement is only that each field can register local keymaps or field-specific actions.

---

## 12. Add Optional `datepicker.nvim` Lazy Spec Example

This belongs in documentation, not TaskNotes runtime code.

Example:

```lua
{
  "Dzejkop/datepicker.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
}
```

If TaskNotes is packaged as your fork:

```lua
{
  "your-org/tasknotes.nvim",
  dependencies = {
    "folke/snacks.nvim",
    "Dzejkop/datepicker.nvim",
  },
  opts = {
    ui = {
      form_backend = "input-form",
      date_picker = {
        enabled = true,
        backend = "datepicker.nvim",
        week_start = "monday",
      },
    },
  },
}
```

Do not require users to install `datepicker.nvim` if they are fine with manual date entry.

---

## 13. Add a Text Fallback

Fallback behavior should remain useful.

When `datepicker.nvim` is not installed, pressing `<C-d>` should open:

```text
Date YYYY-MM-DD:
```

via `vim.ui.input()`.

This allows the same keymap to work regardless of installed backend.

Fallback implementation is already included in `date_picker.lua`:

```lua
function M.pick_with_text(opts)
  vim.ui.input({
    prompt = opts.title or "Date YYYY-MM-DD: ",
    default = normalize_initial(opts.initial),
  }, function(value)
    ...
  end)
end
```

---

## 14. Add Tests

### `tests/date_picker_spec.lua`

Test:

```text
date_picker.is_valid_date("2026-06-01") returns true
date_picker.is_valid_date("2026-99-01") returns false
date_picker.is_valid_date("2026-02-31") returns false
date_picker.today() returns YYYY-MM-DD
```

Example:

```lua
describe("date_picker", function()
  local date_picker = require("tasknotes.ui.date_picker")

  it("validates YYYY-MM-DD dates", function()
    assert.True(date_picker.is_valid_date("2026-06-01"))
    assert.False(date_picker.is_valid_date("2026-99-01"))
    assert.False(date_picker.is_valid_date("2026-02-31"))
    assert.False(date_picker.is_valid_date("not-a-date"))
  end)

  it("returns today's date in YYYY-MM-DD format", function()
    assert.matches("^%d%d%d%d%-%d%d%-%d%d$", date_picker.today())
  end)
end)
```

### `tests/form_date_fields_spec.lua`

Test:

```text
due field includes date picker keymaps
scheduled field includes date picker keymaps
form output normalizes blank due to nil
form output normalizes blank scheduled to nil
selected date is passed as YYYY-MM-DD
```

Example:

```lua
describe("form date fields", function()
  local form_fields = require("tasknotes.ui.form_fields")

  it("normalizes blank dates to nil", function()
    local data = form_fields.form_values_to_task_data({
      title = "Test",
      status = "open",
      priority = "none",
      due = "",
      scheduled = "",
      contexts = "",
      projects = "",
      tags = "",
      blockedBy = "",
      timeEstimate = "",
      body = "",
    })

    assert.is_nil(data.due)
    assert.is_nil(data.scheduled)
  end)
end)
```

---

## 15. Add Docs

Create:

```text
docs/date-picker.md
```

Suggested content:

```markdown
# Date Picker

TaskNotes supports enhanced date selection for `due` and `scheduled` fields when using the `input-form.nvim` form backend.

## Keymaps

When focused on a date field:

| Key | Action |
|---|---|
| `<C-d>` | Open date picker |
| `<C-t>` | Set today |
| `<C-x>` | Clear date |

Manual date input is still supported.

## Date Format

TaskNotes stores dates as:

```text
YYYY-MM-DD
```

## Backend

Recommended backend:

```text
Dzejkop/datepicker.nvim
```

Example config:

```lua
require("tasknotes").setup({
  ui = {
    form_backend = "input-form",
    date_picker = {
      enabled = true,
      backend = "datepicker.nvim",
      fallback_backend = "text",
      week_start = "monday",
    },
  },
})
```

If `datepicker.nvim` is unavailable, TaskNotes falls back to `vim.ui.input()`.
```

---

## 16. Implementation Order

### Step 1: Add config

Modify:

```text
lua/tasknotes/config.lua
```

Add:

```lua
ui.date_picker
```

### Step 2: Add adapter

Create:

```text
lua/tasknotes/ui/date_picker.lua
```

Implement:

```lua
pick_date()
pick_with_datepicker_nvim()
pick_with_text()
today()
is_valid_date()
```

### Step 3: Update validation

Modify or create:

```text
lua/tasknotes/ui/form_validation.lua
```

Add:

```lua
validate_date()
normalize_optional_date()
```

### Step 4: Update form fields

Modify:

```text
lua/tasknotes/ui/form_fields.lua
```

Add:

```lua
date_field_keymaps()
```

Apply it to:

```text
due
scheduled
```

### Step 5: Update task form

Modify:

```text
lua/tasknotes/ui/task_form.lua
```

Ensure form creation uses:

```lua
form_fields.create_task_fields()
form_fields.form_values_to_task_data()
```

### Step 6: Update dependency warnings

Modify:

```text
lua/tasknotes/init.lua
```

Add optional `datepicker.nvim` warning only when:

```text
ui.date_picker.enabled = true
ui.date_picker.backend = "datepicker.nvim"
datepicker.nvim is unavailable
```

### Step 7: Add tests

Add:

```text
tests/date_picker_spec.lua
tests/form_date_fields_spec.lua
```

### Step 8: Add docs

Add:

```text
docs/date-picker.md
```

---

## 17. Acceptance Criteria

The feature is complete when:

```text
Due Date field supports manual YYYY-MM-DD input
Scheduled Date field supports manual YYYY-MM-DD input
<C-d> opens datepicker.nvim when installed
<C-d> falls back to vim.ui.input() when datepicker.nvim is missing
<C-t> sets focused date field to today
<C-x> clears focused date field
Selected date writes back to the active field as YYYY-MM-DD
Blank due/scheduled values normalize to nil
Invalid dates fail validation
Task creation writes selected due/scheduled dates to frontmatter
Task editing preserves and updates due/scheduled dates
Task body editing still works
Task lifecycle hooks still receive the final mutated frontmatter
No setup failure occurs when datepicker.nvim is missing
```

---

## 18. Final Recommended Architecture

```text
tasknotes.nvim
├── lua/
│   └── tasknotes/
│       ├── config.lua
│       ├── init.lua
│       ├── task_manager.lua
│       └── ui/
│           ├── task_form.lua
│           ├── form_fields.lua
│           ├── form_validation.lua
│           ├── date_picker.lua
│           └── time_tracker.lua
├── docs/
│   ├── hooks.md
│   ├── form.md
│   └── date-picker.md
└── tests/
    ├── hooks_spec.lua
    ├── task_identity_spec.lua
    ├── body_update_spec.lua
    ├── date_picker_spec.lua
    └── form_date_fields_spec.lua
```

The key design decision is that TaskNotes owns the date picker adapter:

```lua
require("tasknotes.ui.date_picker").pick_date(...)
```

The form does not call `datepicker.nvim` directly.

This keeps the UI flexible, makes `datepicker.nvim` optional, and allows future backends such as `calendar.nvim`, an orgmode-derived picker, or a fully native TaskNotes picker without changing the task form itself.
