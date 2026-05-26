-- Tests for urgency scoring system
local new_set = MiniTest.new_set
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local helpers = require('tests.tasknotes_helpers')

local child = helpers.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[TaskManager = require('tasknotes.task_manager')]])
      child.lua([[Urgency = require('tasknotes.urgency')]])
      child.lua([[Config = require('tasknotes.config')]])
      -- Initialize config with property-based identification (default is tag-based)
      child.lua([[Config.setup({ task_identification_method = 'property' })]])
    end,
    post_once = child.stop,
  },
})

-- Test urgency calculation
T['calculate_urgency'] = new_set()

T['calculate_urgency']['assigns zero urgency to completed tasks'] = function()
  local vault_path = helpers.create_test_vault(child)
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Completed Task',
    status = 'done',
    priority = 'high',
    due = '2025-12-01',
  })

  child.lua(string.format("Config.options.vault_path = '%s'", vault_path))
  child.lua("TaskManager.scan_vault()")

  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  -- Completed tasks should have very low urgency
  eq(task.urgency < 0, true)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['calculates urgency for open task with high priority'] = function()
  local vault_path = helpers.create_test_vault(child)
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'High Priority Task',
    status = 'open',
    priority = 'high',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  -- High priority should give 6.0 urgency
  eq(task.urgency, 6.0)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['calculates urgency for normal priority task'] = function()
  local vault_path = helpers.create_test_vault(child)
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Normal Priority Task',
    status = 'open',
    priority = 'normal',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  -- Normal priority should give 3.9 urgency (Taskwarrior default)
  -- Note: May have tiny age component for newly created tasks, so check approximately
  eq(task.urgency >= 3.9 and task.urgency < 4.0, true)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['adds urgency for in-progress status'] = function()
  local vault_path = helpers.create_test_vault(child)
  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'In Progress Task',
    status = 'in-progress',
    priority = 'normal',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  -- Normal priority (3.9) + in-progress (4.0) = 7.9
  -- Note: May have tiny age component for newly created tasks, so check approximately
  eq(task.urgency >= 7.9 and task.urgency < 8.0, true)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['adds urgency for due date proximity'] = function()
  local vault_path = helpers.create_test_vault(child)

  -- Get today's date for testing
  local today = child.lua_get([[os.date('!%Y-%m-%d')]])

  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Due Today',
    status = 'open',
    priority = 'none',
    due = today,
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })

  -- Due today should add close to max due urgency (12.0)
  -- Total should be close to 12.0 (no priority, just due date)
  eq(task.urgency > 10, true)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['reduces urgency for blocked tasks'] = function()
  local vault_path = helpers.create_test_vault(child)

  -- Create blocking task first
  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'open',
    priority = 'high',
  })

  -- Create blocked task
  local blocked_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task',
    status = 'open',
    priority = 'high',
    blockedBy = { blocking_path },
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local blocking_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocking_path })
  local blocked_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocked_path })

  -- Blocked task should have lower urgency due to -5.0 penalty
  -- High priority (6.0) + blocked penalty (-5.0) = 1.0
  eq(blocked_task.urgency, 1.0)

  helpers.cleanup_vault(child, vault_path)
end

T['calculate_urgency']['increases urgency for tasks blocking others'] = function()
  local vault_path = helpers.create_test_vault(child)

  -- Create blocking task
  local blocking_path = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocking Task',
    status = 'open',
    priority = 'normal',
  })

  -- Create two blocked tasks
  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task 1',
    status = 'open',
    blockedBy = { blocking_path },
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Blocked Task 2',
    status = 'open',
    blockedBy = { blocking_path },
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local blocking_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { blocking_path })

  -- Normal priority (3.9) + blocks 2 tasks (2 * 8.0) = 19.9 (Taskwarrior defaults)
  -- Note: May have tiny age component for newly created tasks, so check approximately
  eq(blocking_task.urgency >= 19.9 and blocking_task.urgency < 20.0, true)

  helpers.cleanup_vault(child, vault_path)
end

-- Test urgency sorting
T['sort_by_urgency'] = new_set()

T['sort_by_urgency']['sorts tasks by urgency descending'] = function()
  local vault_path = helpers.create_test_vault(child)

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Low Urgency',
    status = 'open',
    priority = 'low',
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'High Urgency',
    status = 'open',
    priority = 'high',
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Medium Urgency',
    status = 'open',
    priority = 'normal',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local tasks = child.lua_get([[TaskManager.get_tasks()]])
  local sorted = child.lua_get([[Urgency.sort_by_urgency(...)]], { tasks })

  -- First task should be high priority (highest urgency)
  eq(sorted[1].title, 'High Urgency')
  -- Last task should be low priority (lowest urgency)
  eq(sorted[#sorted].title, 'Low Urgency')

  helpers.cleanup_vault(child, vault_path)
end

-- Test completed task filtering
T['hide_completed'] = new_set()

T['hide_completed']['filters out completed tasks when enabled'] = function()
  local vault_path = helpers.create_test_vault(child)

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Open Task',
    status = 'open',
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Done Task',
    status = 'done',
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'In Progress Task',
    status = 'in-progress',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])

  -- With hide_completed = true (default), should only get non-completed tasks
  local tasks = child.lua_get([[TaskManager.get_tasks()]])

  -- Should have 2 tasks (open and in-progress, not done)
  eq(#tasks, 2)

  -- Check that done task is not in results
  local has_done = false
  for _, task in ipairs(tasks) do
    if task.title == 'Done Task' then
      has_done = true
      break
    end
  end
  eq(has_done, false)

  helpers.cleanup_vault(child, vault_path)
end

T['hide_completed']['includes completed tasks when filtering by status=done'] = function()
  local vault_path = helpers.create_test_vault(child)

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Open Task',
    status = 'open',
  })

  helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Done Task',
    status = 'done',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])

  -- When explicitly filtering for status=done, should show completed tasks
  local tasks = child.lua_get([[TaskManager.get_tasks({status = 'done'})]])

  -- Should have 1 task
  eq(#tasks, 1)
  eq(tasks[1].title, 'Done Task')

  helpers.cleanup_vault(child, vault_path)
end

-- Test urgency updates
T['urgency_updates'] = new_set()

T['urgency_updates']['recalculates urgency on task update'] = function()
  local vault_path = helpers.create_test_vault(child)

  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Test Task',
    status = 'open',
    priority = 'normal',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local initial_urgency = task.urgency

  -- Update to high priority
  child.lua([[TaskManager.update_task(..., {priority = 'high'})]], { filepath })

  local updated_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local new_urgency = updated_task.urgency

  -- Urgency should increase after priority change
  eq(new_urgency > initial_urgency, true)

  helpers.cleanup_vault(child, vault_path)
end

T['urgency_updates']['recalculates urgency when task becomes in-progress'] = function()
  local vault_path = helpers.create_test_vault(child)

  local filepath = helpers.create_test_task(child, vault_path, {
    type = 'task',
    title = 'Test Task',
    status = 'open',
    priority = 'normal',
  })

  child.lua(string.format([[Config.options.vault_path = '%s']], vault_path))
  child.lua([[TaskManager.scan_vault()]])
  local task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local initial_urgency = task.urgency

  -- Change status to in-progress
  child.lua([[TaskManager.update_task(..., {status = 'in-progress'})]], { filepath })

  local updated_task = child.lua_get([[TaskManager.get_task_by_path(...)]], { filepath })
  local new_urgency = updated_task.urgency

  -- Should add 4.0 for in-progress status
  eq(new_urgency, initial_urgency + 4.0)

  helpers.cleanup_vault(child, vault_path)
end

return T
