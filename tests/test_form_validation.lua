local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local T = new_set()

local validation = require('tasknotes.ui.form_validation')

T['validate_date accepts valid YYYY-MM-DD'] = function()
  local ok = validation.validate_date('2026-05-26')
  eq(ok, true)
end

T['validate_date accepts empty string'] = function() eq(validation.validate_date(''), true) end
T['validate_date accepts nil'] = function() eq(validation.validate_date(nil), true) end
T['validate_date rejects invalid month'] = function() eq(select(1, validation.validate_date('2026-99-01')), false) end
T['validate_date rejects impossible day'] = function() eq(select(1, validation.validate_date('2026-02-31')), false) end
T['validate_date rejects non-date string'] = function() eq(select(1, validation.validate_date('nope')), false) end
T['validate_time_estimate accepts positive integer'] = function() eq(validation.validate_time_estimate('15'), true) end
T['validate_time_estimate accepts empty string'] = function() eq(validation.validate_time_estimate(''), true) end
T['validate_time_estimate rejects negative number'] = function() eq(select(1, validation.validate_time_estimate('-1')), false) end
T['validate_time_estimate rejects decimal'] = function() eq(select(1, validation.validate_time_estimate('2.5')), false) end
T['validate_time_estimate rejects non-number string'] = function() eq(select(1, validation.validate_time_estimate('abc')), false) end

T['normalize_csv splits and trims values'] = function()
  eq(validation.normalize_csv('a, b, c '), { 'a', 'b', 'c' })
end

T['normalize_csv returns empty table for empty string'] = function() eq(validation.normalize_csv(''), {}) end
T['normalize_csv returns empty table for nil'] = function() eq(validation.normalize_csv(nil), {}) end
T['normalize_optional_date returns nil for empty string'] = function() eq(validation.normalize_optional_date(''), nil) end
T['normalize_optional_date returns nil for nil'] = function() eq(validation.normalize_optional_date(nil), nil) end
T['normalize_optional_date passes through valid date'] = function() eq(validation.normalize_optional_date('2026-05-26'), '2026-05-26') end

T['validate_task_data requires title'] = function()
  local ok = validation.validate_task_data({ title = '' })
  eq(ok, false)
end

T['validate_task_data rejects invalid due date'] = function()
  local ok = validation.validate_task_data({ title = 'x', due = '2026-99-01' })
  eq(ok, false)
end

T['validate_task_data accepts valid complete data'] = function()
  local ok = validation.validate_task_data({
    title = 'x', due = '2026-05-26', scheduled = '2026-05-27', timeEstimate = '30',
  })
  eq(ok, true)
end

return T
