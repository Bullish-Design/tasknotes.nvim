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
  local callbacks = opts and opts.callbacks or nil
  local cb = callbacks and callbacks[callback_name] or nil

  if type(cb) == "function" then
    return cb(ctx)
  end
end

return M
