local M = {}

local config = require("tasknotes.config")
local task_manager = require("tasknotes.task_manager")
local hooks = require("tasknotes.hooks")

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

        local current_file = vim.api.nvim_buf_get_name(0)
        if current_file == task.path then
          vim.cmd("edit!")
        end
      end
    end,
  })

  form:show()
end

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
