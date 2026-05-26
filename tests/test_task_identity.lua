local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.helpers')

local child = helpers.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      local temp_vault = child.lua_get([[vim.fn.tempname()]])
      child.lua(string.format([[vim.fn.mkdir('%s', 'p'); Config=require('tasknotes.config'); Config.setup({vault_path='%s'}); TM=require('tasknotes.task_manager')]], temp_vault, temp_vault))
    end,
    post_once = child.stop,
  },
})

T['task_identity'] = new_set()

T['task_identity']['generate_task_id slugifies and formats'] = function()
  local id = child.lua_get([[TM.generate_task_id('My Great Task!!!')]])
  eq(id:match('^task%-%d%d%d%d%d%d%d%d%d%d%d%d%d%d%-.+$') ~= nil, true)
  eq(id:match('%-my%-great%-task$') ~= nil, true)
end

T['task_identity']['generate_task_id truncates long titles'] = function()
  local id = child.lua_get([[TM.generate_task_id(string.rep('a', 120))]])
  local slug = id:gsub('^task%-%d%d%d%d%d%d%d%d%d%d%d%d%d%d%-', '')
  eq(#slug <= 40, true)
end

T['task_identity']['create_task generates id when configured'] = function()
  local task = child.lua_get([[TM.create_task({ title = 'Auto Id Task', tags = {'task'} })]])
  eq(task ~= nil, true)
  eq(type(task.id), 'string')
  eq(task.id:match('^task%-') ~= nil, true)
end

T['task_identity']['create_task uses provided id'] = function()
  local task = child.lua_get([[TM.create_task({ title = 'Provided Id Task', id = 'task-custom-123', tags = {'task'} })]])
  eq(task.id, 'task-custom-123')
end

T['task_identity']['get_task_by_id and resolve_task by id/path'] = function()
  local task = child.lua_get([[TM.create_task({ title = 'Lookup Task', tags = {'task'} })]])
  local by_id = child.lua_get([[TM.get_task_by_id(...)]], { task.id })
  local by_path = child.lua_get([[TM.resolve_task(...)]], { task.path })
  local by_ref_id = child.lua_get([[TM.resolve_task(...)]], { task.id })
  eq(by_id.path, task.path)
  eq(by_path.id, task.id)
  eq(by_ref_id.path, task.path)
end

T['task_identity']['resolve_task returns nil for unknown ref'] = function()
  local v = child.lua_get([[TM.resolve_task('task-does-not-exist') == nil]])
  eq(v, true)
end

return T
