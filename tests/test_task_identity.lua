local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.helpers')

local child = helpers.new_child_neovim()
local T = new_set({ hooks = { pre_case = function() child.setup() end, post_once = child.stop } })

T['ids'] = new_set()

T['ids']['generate_task_id format'] = function()
  local id = child.lua_get([[require('tasknotes.task_manager').generate_task_id('My Task')]])
  expect.equality(id:match('^task%-%d%d%d%d%d%d%d%d%d%d%d%d%d%d%-.+'), id)
end

T['ids']['resolve by id and path'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua(string.format([[Config=require('tasknotes.config'); Config.setup({vault_path='%s'}); TM=require('tasknotes.task_manager')]], vault))
  local task = child.lua_get([[TM.create_task({ title = 'Identity Task', tags = {'task'} })]])
  local by_id = child.lua_get([[TM.get_task_by_id(...)]], { task.id })
  local by_ref = child.lua_get([[TM.resolve_task(...)]], { task.id })
  eq(by_id.path, task.path)
  eq(by_ref.path, task.path)
  helpers.cleanup_vault(child, vault)
end

return T
