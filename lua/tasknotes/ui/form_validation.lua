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
