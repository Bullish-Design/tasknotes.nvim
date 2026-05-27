# Changelog

All notable changes to tasknotes.nvim will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-26

### Added

- input-form.nvim backend with typed fields (`text`, `select`, `multiline`, `spacer`)
- Per-field date keymaps and date picker integration with text fallback
- Per-field completion for CSV fields (`contexts`, `projects`, `tags`)
- Form validation/normalization modules and coverage tests
- Body-aware task update flow with additional tests
- Hook/event system integration and tests
- Devenv-based developer shell/test workflow

### Changed

- Form backend is now configurable with `ui.form_backend` and NUI fallback behavior
- Dependency checks are backend-aware and no longer hard-fail for optional UI paths
- NUI form behavior preserved as degraded fallback when input-form is unavailable

## [0.1.0] - 2025-01-20

### Added

- Initial release of tasknotes.nvim
- Core task management functionality
  - Browse tasks with Telescope integration
  - Create new tasks with NUI forms
  - Edit existing task metadata
  - Delete tasks with confirmation
- YAML frontmatter support
  - Parse TaskNotes file format
  - Field mapping customization
  - Support for all standard TaskNotes fields
- Time tracking
  - Start/stop timers for tasks
  - Automatic time entry recording
  - View time entries history
  - Statusline integration for active timers
- Configuration system
  - Customizable statuses and priorities
  - Configurable UI styling
  - Custom keymaps
  - Field mapping for different vault structures
- Telescope integration
  - Custom entry display showing task metadata
  - Inline actions (mark done, edit, delete, toggle timer)
  - Filter by status, priority, context
  - File preview support
- Commands
  - `:TaskNotesBrowse` - Browse all tasks
  - `:TaskNotesNew` - Create new task
  - `:TaskNotesEdit` - Edit current task
  - `:TaskNotesRescan` - Rescan vault
  - `:TaskNotesTimerToggle` - Toggle timer
  - `:TaskNotesTimerStatus` - Show timer status
  - `:TaskNotesTimeEntries` - View time entries
  - Filter commands for status, priority, context
- Documentation
  - Comprehensive README
  - Quick Start Guide
  - API documentation (Vim help)
  - Example configurations
  - Sample task file
  - Contributing guidelines
  - Roadmap for future features

### Dependencies

- nui.nvim (required)
- telescope.nvim (optional but recommended)
- plenary.nvim (optional but recommended)
- yq (optional, for improved YAML parsing)

[Unreleased]: https://github.com/Bullish-Design/tasknotes.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Bullish-Design/tasknotes.nvim/releases/tag/v0.2.0
[0.1.0]: https://github.com/emiller/tasknotes.nvim/releases/tag/v0.1.0
