local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local T = new_set()

local config = require('tasknotes.config')
config.setup({})
local date_picker = require('tasknotes.ui.date_picker')

T['is_valid_date returns true for valid date'] = function() eq(date_picker.is_valid_date('2026-05-26'), true) end
T['is_valid_date returns false for invalid month'] = function() eq(date_picker.is_valid_date('2026-13-01'), false) end
T['is_valid_date returns false for impossible day'] = function() eq(date_picker.is_valid_date('2026-02-31'), false) end
T['is_valid_date returns false for non-date string'] = function() eq(date_picker.is_valid_date('abc'), false) end
T['is_valid_date returns false for empty string'] = function() eq(date_picker.is_valid_date(''), false) end
T['is_valid_date returns false for nil'] = function() eq(date_picker.is_valid_date(nil), false) end

T['today returns YYYY-MM-DD format'] = function()
  local t = date_picker.today()
  eq(type(t), 'string')
  eq(t:match('^%d%d%d%d%-%d%d%-%d%d$') ~= nil, true)
end

return T
