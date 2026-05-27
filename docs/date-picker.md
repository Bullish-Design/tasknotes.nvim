# Date Picker

TaskNotes supports calendar-based date selection for `due` and `scheduled`
fields when using the `input-form.nvim` form backend.

## Keymaps

When focused on a date field:

| Key | Action |
|-----|--------|
| `<C-d>` | Open date picker |
| `<C-t>` | Set today's date |
| `<C-x>` | Clear date |

Manual date input (`YYYY-MM-DD`) is always supported.

## Configuration

```lua
require("tasknotes").setup({
  ui = {
    form_backend = "input-form",
    date_picker = {
      enabled = true,
      backend = "datepicker.nvim",
      fallback_backend = "text",
      week_start = "monday",
      keymaps = {
        open = "<C-d>",
        clear = "<C-x>",
        today = "<C-t>",
      },
    },
  },
})
```

## Backends

### datepicker.nvim (recommended)

Floating calendar widget. Requires [Dzejkop/datepicker.nvim](https://github.com/Dzejkop/datepicker.nvim).

### text

Falls back to `vim.ui.input()` with date validation. Used automatically
when `datepicker.nvim` is not installed.

## Date Format

Dates are stored as `YYYY-MM-DD` in task frontmatter.
