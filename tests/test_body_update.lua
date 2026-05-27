local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function() child.setup() end,
    post_once = child.stop,
  },
})

local function setup_with_callbacks(vault)
  child.lua(string.format([[
    Config=require('tasknotes.config')
    Config.setup({ vault_path='%s', callbacks=_G._callbacks })
    TM=require('tasknotes.task_manager')
    Parser=require('tasknotes.parser')
  ]], vault))
end

local function create_task_with_body(vault, body)
  return helpers.create_test_task(child, vault, {
    id = 'task-1',
    title = 'Body Test',
    status = 'open',
    tags = { 'task' },
  }, body, 'body-test.md')
end

T['update_task preserves body when update_opts not provided'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {}]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., { status = 'done' })]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.body, '\nOriginal body')
  eq(parsed.frontmatter.status, 'done')

  helpers.cleanup_vault(child, vault)
end

T['update_task preserves body when update_opts is empty'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {}]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., { status = 'done' }, {})]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.body, '\nOriginal body')
  eq(parsed.frontmatter.status, 'done')

  helpers.cleanup_vault(child, vault)
end

T['update_task replaces body when update_opts.body is provided'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {}]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., { status = 'done' }, { body = 'New body' })]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.body, 'New body')
  eq(parsed.frontmatter.status, 'done')

  helpers.cleanup_vault(child, vault)
end

T['update_task accepts empty string body (clears body)'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {}]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., {}, { body = '' })]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.body, '')

  helpers.cleanup_vault(child, vault)
end

T['update_task does not write body key into frontmatter'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {}]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., { body = 'sneaky' }, {})]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.frontmatter.body, nil)
  eq(parsed.body, '\nOriginal body')

  helpers.cleanup_vault(child, vault)
end

T['update_task body is available in before_task_update ctx'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {
    before_task_update = function(ctx) _G._seen_body = ctx.body end,
  }]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., {}, { body = 'Hook body' })]], { path })
  eq(ok, true)
  eq(child.lua_get([[_G._seen_body]]), 'Hook body')

  helpers.cleanup_vault(child, vault)
end

T['update_task body mutation in before_task_update callback is respected'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {
    before_task_update = function(ctx) ctx.body = 'Mutated by hook' end,
  }]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., {}, { body = 'Caller body' })]], { path })
  eq(ok, true)
  local parsed = child.lua_get([[Parser.parse_file(...)]], { path })
  eq(parsed.body, 'Mutated by hook')

  helpers.cleanup_vault(child, vault)
end

T['after_task_update ctx.task.body reflects the final body'] = function()
  local vault = helpers.create_test_vault(child)
  child.lua([[_G._callbacks = {
    after_task_update = function(ctx) _G._after_body = ctx.task and ctx.task.body or nil end,
  }]])
  setup_with_callbacks(vault)
  local path = create_task_with_body(vault, 'Original body')

  local ok = child.lua_get([[TM.update_task(..., {}, { body = 'Final body' })]], { path })
  eq(ok, true)
  eq(child.lua_get([[_G._after_body]]), 'Final body')

  helpers.cleanup_vault(child, vault)
end

return T
