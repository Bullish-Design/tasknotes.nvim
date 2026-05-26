local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.helpers')

local child = helpers.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function() child.setup() end,
    post_once = child.stop,
  },
})

local function setup_with_callbacks(vault, callbacks)
  child.lua(string.format([[
    Config=require('tasknotes.config')
    Config.setup({ vault_path='%s', callbacks=_G._callbacks })
    TM=require('tasknotes.task_manager')
  ]], vault))
end

T['hooks'] = new_set()

T['hooks']['before/after create callbacks fire'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {
    before_task_create = function(ctx) _G.before_ok = (ctx.operation == 'create' and ctx.frontmatter ~= nil) end,
    after_task_create = function(ctx) _G.after_ok = (ctx.task ~= nil and ctx.task.path ~= nil) end,
  }]])
  setup_with_callbacks(vault)
  child.lua([[TM.create_task({ title = 'Hook Create', tags = {'task'} })]])
  eq(child.lua_get([[_G.before_ok]]), true)
  eq(child.lua_get([[_G.after_ok]]), true)
  helpers.cleanup_vault(child, vault)
end

T['hooks']['create cancellation via return false'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = { before_task_create = function(_) return false end }]])
  setup_with_callbacks(vault)
  local is_nil = child.lua_get([[TM.create_task({ title = 'No Create', tags = {'task'} }) == nil]])
  eq(is_nil, true)
  helpers.cleanup_vault(child, vault)
end

T['hooks']['update cancellation via ctx.cancel'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = { before_task_update = function(ctx) ctx.cancel = true end }]])
  setup_with_callbacks(vault)
  local task = child.lua_get([[TM.create_task({ title = 'Cancel Update', tags = {'task'} })]])
  local ok = child.lua_get([[TM.update_task(..., { status = 'done' })]], { task.path })
  eq(ok, false)
  helpers.cleanup_vault(child, vault)
end

T['hooks']['delete cancellation via return false'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = { before_task_delete = function(_) return false end }]])
  setup_with_callbacks(vault)
  local task = child.lua_get([[TM.create_task({ title = 'Cancel Delete', tags = {'task'} })]])
  local ok = child.lua_get([[TM.delete_task(...)]], { task.path })
  eq(ok, false)
  helpers.cleanup_vault(child, vault)
end

T['hooks']['before_create mutation can override path'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {
    before_task_create = function(ctx)
      ctx.path = ctx.path:gsub('%.md$', '-moved.md')
      ctx.frontmatter.customField = 'yes'
    end,
  }]])
  setup_with_callbacks(vault)
  local task = child.lua_get([[TM.create_task({ title = 'Mutate Path', tags = {'task'} })]])
  eq(task.path:match('%-moved%.md$') ~= nil, true)
  helpers.cleanup_vault(child, vault)
end

return T
