local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.helpers')

local child = helpers.new_child_neovim()
local T = new_set({ hooks = { pre_case = function() child.setup() end, post_once = child.stop } })

T['hooks'] = new_set()

T['hooks']['create callbacks fire'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua(string.format([[
    _G.before=false; _G.after=false
    Config=require('tasknotes.config')
    Config.setup({
      vault_path='%s',
      callbacks={
        before_task_create=function(ctx) _G.before = ctx.operation == 'create' end,
        after_task_create=function(ctx) _G.after = ctx.task ~= nil end,
      }
    })
    TM=require('tasknotes.task_manager')
    TM.create_task({ title = 'Hook Task', tags = {'task'} })
  ]], vault))
  eq(child.lua_get([[_G.before]]), true)
  eq(child.lua_get([[_G.after]]), true)
  helpers.cleanup_vault(child, vault)
end

T['hooks']['create cancellation works'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua(string.format([[
    Config=require('tasknotes.config')
    Config.setup({ vault_path='%s', callbacks={ before_task_create=function(ctx) ctx.cancel=true end } })
    TM=require('tasknotes.task_manager')
    _G.ret = TM.create_task({ title = 'Nope', tags = {'task'} })
  ]], vault))
  eq(child.lua_get([[_G.ret == nil]]), true)
  helpers.cleanup_vault(child, vault)
end

return T
