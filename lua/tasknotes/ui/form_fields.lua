local M = {}

local config = require("tasknotes.config")
local validation = require("tasknotes.ui.form_validation")

local function date_field_keymaps(_field_name, title)
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

function M.create_task_fields(task, form_opts)
  task = task or {}
  form_opts = form_opts or {}
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
