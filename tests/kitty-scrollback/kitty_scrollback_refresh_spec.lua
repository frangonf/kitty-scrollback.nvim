local api = require('kitty-scrollback.api')
local assert = require('luassert.assert')
local h = require('tests.kitty-scrollback.helpers')
local kitty_commands = require('kitty-scrollback.kitty_commands')
local stub = require('luassert.stub')

local p
local opts
local kitty_instance
local original_listen_on = vim.env.KITTY_LISTEN_ON
local notify_stub
local tempfile_stub
local ui_stub
local open_term_stub
local notifications
local original_ui_send = vim.api.nvim_ui_send
local original_termsync = vim.fn.exists('+termsync') == 1 and vim.o.termsync

local function record_presentation()
  local messages = {}
  ui_stub = stub(vim.api, 'nvim_ui_send', function(data)
    table.insert(messages, { data, vim.o.termsync, vim.o.columns })
  end)
  return messages
end

local function lines()
  return vim.api.nvim_buf_get_lines(p.bufid, 0, -1, false)
end

local function view()
  return vim.api.nvim_win_call(p.winid, function()
    local saved = vim.fn.winsaveview()
    return { saved.lnum, saved.col, saved.topline, saved.leftcol }
  end)
end

local function append(text)
  h.kitty_remote_send_text(text .. '\n')
  assert.is_true(vim.wait(3000, function()
    return h.kitty_remote_get_text().stdout:find(text:match('[^\n]+$'), 1, true) ~= nil
  end))
end

describe('scrollback refresh', function()
  before_each(function()
    notifications = {}
    notify_stub = stub(vim, 'notify', function(message, level)
      table.insert(notifications, { message = message, level = level })
    end)
    local socket = h.tempsocket('/tmp/')
    kitty_instance = h.wait_for_kitty_remote_connection({
      h.kitty,
      '--config',
      'NONE',
      '--listen-on=unix:' .. socket,
      '--override',
      'allow_remote_control=yes',
      '--override',
      'scrollback_lines=200',
      '/bin/sh',
      '-c',
      'stty -echo; i=1; while [ "$i" -le 100 ]; do printf "line %03d sample output\\n" "$i"; i=$((i+1)); done; exec cat',
    }, socket, {})
    vim.env.KITTY_LISTEN_ON = 'unix:' .. socket
    vim.cmd.enew()
    vim.o.scrollback = 100000
    vim.o.virtualedit = 'all'
    vim.o.scrolloff = 0
    vim.wo.wrap = false
    p = {
      bufid = vim.api.nvim_get_current_buf(),
      winid = vim.api.nvim_get_current_win(),
      orig_options = { shell = vim.o.shell },
      kitty_data = { kitty_path = 'kitty', window_id = 1, shell = '/bin/sh' },
    }
    opts = vim.deepcopy(require('kitty-scrollback.configs.defaults'))
    api.setup(p, opts)
    vim.g.mapleader = ' '
    require('kitty-scrollback').setup()
    require('kitty-scrollback.keymaps').setup(p, opts)
    require('kitty-scrollback.keymaps').set_scrollback_keymaps(p.bufid)
    kitty_commands.setup(p, opts)
    local ready = false
    kitty_commands.get_text_term({ kitty = '--extent=all --ansi --add-wrap-markers' }, function()
      ready = true
    end)
    assert.is_true(vim.wait(5000, function()
      return ready
    end))
    vim.fn.winrestview({ lnum = 40, col = 8, topline = 30 })
  end)

  after_each(function()
    vim.env.KITTY_LISTEN_ON = original_listen_on
    notify_stub:revert()
    if ui_stub then
      ui_stub:revert()
      ui_stub = nil
    end
    vim.api.nvim_ui_send = original_ui_send
    if open_term_stub then
      open_term_stub:revert()
      open_term_stub = nil
    end
    if vim.fn.exists('+termsync') == 1 then
      vim.o.termsync = original_termsync
    end
    if tempfile_stub then
      tempfile_stub:revert()
      tempfile_stub = nil
    end
    kitty_instance:kill(15)
    pcall(vim.keymap.del, 'n', '<leader>R')
    pcall(vim.keymap.del, 'n', '<leader>r')
    vim.cmd('silent! %bwipeout!')
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'VimLeavePre' })) do
      assert.is_false(
        autocmd.desc == 'Restore Kitty refresh presentation',
        'presentation cleanup leaked'
      )
    end
  end)

  if original_ui_send and vim.fn.exists('+termsync') == 1 then
    it('publishes refresh atomically and restores termsync before readiness hooks', function()
      local messages = record_presentation()
      local columns = vim.o.columns
      for i, enabled in ipairs({ true, false }) do
        vim.o.termsync = enabled
        local observed
        vim.api.nvim_create_autocmd('FileType', {
          pattern = 'kitty-scrollback',
          once = true,
          callback = function()
            observed = { #messages, vim.o.termsync, vim.o.columns }
          end,
        })
        local oldbuf = p.bufid

        api.refresh()

        assert.equals(2 * (i - 1), #messages, 'fetching must stay outside synchronized output')
        assert.is_true(vim.wait(5000, function()
          return p.bufid ~= oldbuf and not p.refreshing
        end))
        assert.equals(2 * i, #messages)
        assert.same({ '\27[?2026h', false, columns }, messages[2 * i - 1])
        assert.same({ '\27[?2026l', false, columns }, messages[2 * i])
        assert.same({ 2 * i, enabled, columns }, observed)
        assert.equals(enabled, vim.o.termsync)
      end
    end)

    it('releases synchronized output if Neovim exits while rendering', function()
      local messages = record_presentation()
      vim.o.termsync = true
      local observed
      vim.api.nvim_create_autocmd('TermOpen', {
        once = true,
        callback = function()
          vim.api.nvim_exec_autocmds('VimLeavePre', {})
          observed = { #messages, vim.o.termsync }
        end,
      })
      local oldbuf = p.bufid

      api.refresh()

      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf and not p.refreshing
      end))
      assert.same({ 2, true }, observed)
      assert.equals(2, #messages)
    end)

    it('cancels and thaws when the staging buffer is deleted before rendering', function()
      local messages = record_presentation()
      vim.o.termsync = true
      local oldbuf, before, columns = p.bufid, view(), vim.o.columns
      vim.api.nvim_create_autocmd('TermOpen', {
        once = true,
        callback = function(e)
          vim.schedule(function()
            vim.api.nvim_buf_delete(e.buf, { force = true })
          end)
        end,
      })

      api.refresh()

      local finished = vim.wait(2000, function()
        return p.refreshing == false
      end)
      if not finished then
        vim.api.nvim_exec_autocmds('VimLeavePre', {})
      end
      assert.is_true(finished)
      assert.equals(oldbuf, p.bufid)
      assert.same(before, view())
      assert.equals(columns, vim.o.columns)
      assert.is_true(vim.o.termsync)
      assert.equals(2, #messages)
    end)

    it('thaws and permits retrying after the staging terminal fails to open', function()
      local messages = record_presentation()
      vim.o.termsync = true
      local oldbuf, before, columns = p.bufid, view(), vim.o.columns
      open_term_stub = stub(vim.api, 'nvim_open_term', function()
        error('terminal preparation failed')
      end)

      api.refresh()

      assert.is_true(vim.wait(5000, function()
        return p.refreshing == false
      end))
      assert.equals(oldbuf, p.bufid)
      assert.same(before, view())
      assert.equals(columns, vim.o.columns)
      assert.is_true(vim.o.termsync)
      assert.equals(2, #messages)
      assert.is_not_nil(notifications[1].message:find('terminal preparation failed', 1, true))
      open_term_stub:revert()
      open_term_stub = nil
      api.refresh()
      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf and not p.refreshing
      end))
      assert.equals(4, #messages)
    end)

    it('restores termsync even if the UI send operation fails', function()
      vim.o.termsync = true
      ui_stub = stub(vim.api, 'nvim_ui_send', function()
        error('UI send failed')
      end)
      local oldbuf, columns = p.bufid, vim.o.columns

      api.refresh()

      assert.is_true(vim.wait(5000, function()
        return p.refreshing == false
      end))
      assert.equals(oldbuf, p.bufid)
      assert.equals(columns, vim.o.columns)
      assert.is_true(vim.o.termsync)
      assert.is_not_nil(notifications[1].message:find('UI send failed', 1, true))
    end)

    it('does not start synchronized output when no width expansion is needed', function()
      local messages = record_presentation()
      opts.scrollback_columns = vim.o.columns
      local oldbuf, before = p.bufid, view()
      local enabled = vim.o.termsync

      api.refresh()

      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf and not p.refreshing
      end))
      assert.equals(0, #messages)
      assert.equals(enabled, vim.o.termsync)
      assert.same(before, view())
    end)
  end

  it('keeps refreshing when the presentation API is unavailable', function()
    vim.api.nvim_ui_send = nil
    local oldbuf, before = p.bufid, view()

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
    assert.same(before, view())
    assert.equals(0, #notifications)
  end)

  it('rolls back and permits retrying after a buffer-switch hook fails', function()
    local messages = original_ui_send and record_presentation()
    local termsync = original_ui_send and vim.o.termsync
    local oldbuf, before = p.bufid, view()
    local columns, count = vim.o.columns, #vim.api.nvim_list_bufs()
    vim.api.nvim_create_autocmd('BufLeave', {
      buffer = oldbuf,
      once = true,
      callback = function()
        error('buffer-switch hook failed')
      end,
    })

    api.refresh()

    local finished = vim.wait(2000, function()
      return p.refreshing == false
    end)
    if not finished then
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
    end
    assert.is_true(finished)
    assert.equals(oldbuf, p.bufid)
    assert.same(before, view())
    assert.equals(columns, vim.o.columns)
    assert.equals(count, #vim.api.nvim_list_bufs())
    assert.is_not_nil(notifications[1].message:find('buffer-switch hook failed', 1, true))
    if messages then
      assert.equals(2, #messages)
      assert.equals(termsync, vim.o.termsync)
    end
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
  end)

  it('rolls back without rerunning failing buffer hooks or closing the draft', function()
    require('kitty-scrollback.util').setup(p, opts)
    local windows = require('kitty-scrollback.windows')
    windows.setup(p, opts)
    require('kitty-scrollback.footer_win').setup(p, opts)
    require('kitty-scrollback.autocommands').setup(p, opts)
    require('kitty-scrollback.autocommands').load_autocmds()
    opts.paste_window.hide_footer = true
    p.pos = {
      cursor_line = 40,
      buf_last_line = #lines(),
      win_first_line = 30,
      win_last_line = 51,
      col = 8,
    }
    windows.open_paste_window()
    vim.api.nvim_buf_set_lines(p.paste_bufid, 0, -1, false, { 'keep this draft' })
    local messages = original_ui_send and record_presentation()
    local termsync = original_ui_send and vim.o.termsync
    local oldbuf, before = p.bufid, view()
    local columns, count = vim.o.columns, #vim.api.nvim_list_bufs()
    local hook_calls = 0
    local hook = vim.api.nvim_create_autocmd('BufEnter', {
      callback = function()
        hook_calls = hook_calls + 1
        error('buffer-entry hook failed')
      end,
    })

    api.refresh()

    local finished = vim.wait(2000, function()
      return p.refreshing == false
    end)
    vim.api.nvim_del_autocmd(hook)
    if not finished then
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
    end
    assert.is_true(finished)
    assert.equals(1, hook_calls)
    assert.equals(oldbuf, p.bufid)
    assert.equals(oldbuf, vim.api.nvim_win_get_buf(p.winid))
    assert.same(before, view())
    assert.equals(columns, vim.o.columns)
    assert.equals(count, #vim.api.nvim_list_bufs())
    assert.equals(p.paste_winid, vim.api.nvim_get_current_win())
    assert.same({ 'keep this draft' }, vim.api.nvim_buf_get_lines(p.paste_bufid, 0, -1, false))
    assert.is_not_nil(notifications[1].message:find('buffer-entry hook failed', 1, true))
    if messages then
      assert.equals(2, #messages)
      assert.equals(termsync, vim.o.termsync)
    end
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
  end)

  it('preserves the text origin and window display options across refreshes', function()
    vim.api.nvim_set_option_value('signcolumn', 'no', { win = p.winid, scope = 'local' })
    vim.api.nvim_set_option_value('statuscolumn', ' ', { win = p.winid, scope = 'local' })
    vim.api.nvim_set_option_value('winhighlight', 'Normal:Search,Visual:IncSearch', {
      win = p.winid,
      scope = 'local',
    })
    vim.cmd.redraw()
    local before = view()
    local origin = vim.fn.screenpos(p.winid, before[3], 1).col
    local gutter = vim.fn.getwininfo(p.winid)[1].textoff
    local options = {}
    for _, name in ipairs({
      'signcolumn',
      'statuscolumn',
      'winhighlight',
      'scrolloff',
      'sidescrolloff',
    }) do
      options[name] = vim.api.nvim_get_option_value(name, { win = p.winid, scope = 'local' })
    end

    for _ = 1, 3 do
      local oldbuf = p.bufid
      api.refresh()
      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf and not p.refreshing
      end))
      for name, value in pairs(options) do
        assert.equals(
          value,
          vim.api.nvim_get_option_value(name, { win = p.winid, scope = 'local' }),
          name
        )
      end
      assert.same(before, view())
      assert.equals(origin, vim.fn.screenpos(p.winid, before[3], 1).col)
      assert.equals(gutter, vim.fn.getwininfo(p.winid)[1].textoff)
    end
  end)

  it('fires FileType only after the snapshot and reading view are ready', function()
    local observed
    local columns = vim.o.columns
    local before = view()
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'kitty-scrollback',
      once = true,
      callback = function(e)
        observed = {
          bufid = e.buf,
          private_bufid = p.bufid,
          winid = vim.api.nvim_get_current_win(),
          columns = vim.o.columns,
          text = table.concat(vim.api.nvim_buf_get_lines(e.buf, 0, -1, false), '\n'),
          view = view(),
        }
        vim.keymap.set('n', '<leader>R', '<Plug>(KsbRefresh)', { buffer = e.buf })
      end,
    })
    append('output visible to the ready hook')
    local oldbuf = p.bufid

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
    assert.is_not_nil(observed)
    assert.equals(p.bufid, observed.private_bufid)
    assert.equals(p.bufid, observed.bufid)
    assert.equals(p.winid, observed.winid)
    assert.equals(columns, observed.columns)
    assert.same(before, observed.view)
    assert.is_not_nil(observed.text:find('output visible to the ready hook', 1, true))
    assert.equals('', vim.fn.maparg('<leader>r', 'n'))
    assert.equals('<Plug>(KsbRefresh)', vim.fn.maparg('<leader>R', 'n'))
  end)

  it('rolls back a failed ready hook without losing the old view or paste draft', function()
    require('kitty-scrollback.util').setup(p, opts)
    local windows = require('kitty-scrollback.windows')
    windows.setup(p, opts)
    require('kitty-scrollback.footer_win').setup(p, opts)
    require('kitty-scrollback.autocommands').setup(p, opts)
    require('kitty-scrollback.autocommands').load_autocmds()
    opts.paste_window.hide_footer = true
    p.pos = {
      cursor_line = 40,
      buf_last_line = #lines(),
      win_first_line = 30,
      win_last_line = 51,
      col = 8,
    }
    windows.open_paste_window()
    vim.api.nvim_buf_set_lines(p.paste_bufid, 0, -1, false, { 'keep this draft' })
    local oldbuf, oldwin, oldpos = p.bufid, p.winid, p.pos
    local before_lines, before_view = lines(), view()
    local columns, count = vim.o.columns, #vim.api.nvim_list_bufs()
    local messages = original_ui_send and record_presentation()
    local termsync = original_ui_send and vim.o.termsync
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'kitty-scrollback',
      once = true,
      callback = function()
        error('ready hook failed')
      end,
    })
    local added = {}
    for i = 101, 500 do
      table.insert(added, ('line %03d sample output'):format(i))
    end
    append(table.concat(added, '\n'))

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.refreshing == false
    end))
    assert.equals(oldbuf, p.bufid)
    assert.equals(oldwin, p.winid)
    assert.equals(oldpos, p.pos)
    assert.same(before_lines, lines())
    assert.same(before_view, view())
    assert.equals(columns, vim.o.columns)
    assert.equals(count, #vim.api.nvim_list_bufs())
    assert.equals(p.paste_winid, vim.api.nvim_get_current_win())
    assert.same({ 'keep this draft' }, vim.api.nvim_buf_get_lines(p.paste_bufid, 0, -1, false))
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
    if messages then
      assert.equals(2, #messages)
      assert.equals(termsync, vim.o.termsync)
    end
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
  end)

  it('keeps the old snapshot and editor size if preparing the replacement fails', function()
    opts.scrollback_tempfile = true
    tempfile_stub = stub(require('kitty-scrollback.util'), 'create_tempfile', function()
      return 'disk full', false
    end)
    local oldbuf = p.bufid
    local before = view()
    local columns = vim.o.columns
    local count = #vim.api.nvim_list_bufs()

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.refreshing == false
    end))
    assert.equals(oldbuf, p.bufid)
    assert.same(before, view())
    assert.equals(columns, vim.o.columns)
    assert.equals(count, #vim.api.nvim_list_bufs())
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
  end)

  it('preserves wide Unicode lines, horizontal scrolling, and temporary-file contents', function()
    local wide = 'wide ' .. string.rep('x', 220) .. ' λ界'
    append(wide)
    local oldbuf = p.bufid
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    local row
    for i, text in ipairs(lines()) do
      if text == wide then
        row = i
      end
    end
    assert.is_not_nil(row, vim.inspect(vim.list_slice(lines(), 95)))
    vim.fn.winrestview({ lnum = row, col = 120, leftcol = 70, topline = row - 10 })
    local before = view()
    opts.scrollback_tempfile = true
    append('next Unicode log λ界')
    oldbuf = p.bufid

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.same(before, view())
    assert.equals(vim.fn.wincol() - 1, p.pos.col)
    local filename = vim.api.nvim_buf_get_name(p.bufid)
    assert.equals(1, vim.fn.filereadable(filename))
    assert.is_not_nil(table.concat(vim.fn.readfile(filename), '\n'):find(wide, 1, true))
    assert.is_not_nil(table.concat(lines(), '\n'):find('next Unicode log λ界', 1, true))
  end)

  it('keeps the full reading view when opening paste after a wide-line refresh', function()
    local wide = 'wide ' .. string.rep('x', 220) .. ' λ界'
    append(wide)
    local oldbuf = p.bufid
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
    local row
    for i, text in ipairs(lines()) do
      if text == wide then
        row = i
      end
    end
    assert.is_not_nil(row)
    vim.fn.winrestview({ lnum = row, col = 120, leftcol = 70, topline = row - 10 })
    local before = view()
    oldbuf = p.bufid
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf and not p.refreshing
    end))
    assert.same(before, view())
    require('kitty-scrollback.util').setup(p, opts)
    local windows = require('kitty-scrollback.windows')
    windows.setup(p, opts)
    require('kitty-scrollback.footer_win').setup(p, opts)
    require('kitty-scrollback.autocommands').setup(p, opts)
    require('kitty-scrollback.autocommands').load_autocmds()
    opts.paste_window.hide_footer = true

    windows.open_paste_window()

    assert.same(before, view())
    assert.equals(p.paste_winid, vim.api.nvim_get_current_win())
  end)

  it('retains the buffer scrollback limit when global options were restored', function()
    vim.api.nvim_set_option_value('scrollback', 10, { scope = 'global' })
    local oldbuf = p.bufid
    local before = view()

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.equals(100000, vim.bo[p.bufid].scrollback)
    assert.same(before, view())
  end)

  it('finishes refreshing an empty source without leaving a pending request', function()
    local cmd =
      vim.list_extend(h.kitty_remote_cmd(), { 'launch', '--type=window', '/bin/sleep', '60' })
    local result = vim.system(cmd):wait()
    assert.equals(0, result.code)
    p.kitty_data.window_id = tonumber(result.stdout)
    local oldbuf = p.bufid

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.is_false(p.refreshing)
    assert.equals('', table.concat(lines(), ''):gsub('%s', ''))
  end)

  it('supports the command and buffer-local shortcut on repeated refreshes', function()
    local count = #vim.api.nvim_list_bufs()
    local oldbuf = p.bufid
    append('one new line, not duplicated')
    vim.cmd.KittyScrollbackRefresh()
    vim.fn.winrestview({ lnum = 50, col = 10, topline = 42 })
    local moved_view = view()
    api.refresh() -- a second request while fetching is ignored
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.same(moved_view, view())
    local mapping = vim.fn.maparg('<leader>r', 'n', false, true)
    assert.equals('<Plug>(KsbRefresh)', mapping.rhs)
    assert.equals(1, mapping.buffer)
    oldbuf = p.bufid

    vim.cmd.normal(' r')

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.same(moved_view, view())
    assert.equals(count, #vim.api.nvim_list_bufs())
    local _, occurrences = table.concat(lines(), '\n'):gsub('one new line, not duplicated', '')
    assert.equals(1, occurrences)
  end)

  it('uses a custom refresh binding instead of the default across refreshes', function()
    vim.keymap.del('n', '<leader>r', { buffer = p.bufid })
    vim.keymap.set('n', '<leader>r', '<cmd>echo "existing action"<cr>')
    vim.keymap.set('n', '<leader>R', '<Plug>(KsbRefresh)')
    require('kitty-scrollback.keymaps').set_scrollback_keymaps(p.bufid)
    assert.equals(0, vim.fn.maparg('<leader>r', 'n', false, true).buffer)

    for _ = 1, 2 do
      local oldbuf = p.bufid
      vim.cmd.normal(' R')
      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf
      end))
      assert.equals(0, vim.fn.maparg('<leader>r', 'n', false, true).buffer)
      assert.equals('<Cmd>echo "existing action"<CR>', vim.fn.maparg('<leader>r', 'n'))
      assert.equals('<Plug>(KsbRefresh)', vim.fn.maparg('<leader>R', 'n'))
    end
  end)

  it('preserves buffer-local refresh remaps and their options across refreshes', function()
    vim.keymap.del('n', '<leader>r', { buffer = p.bufid })
    vim.keymap.set('n', '<leader>r', '<cmd>echo "existing action"<cr>')
    vim.keymap.set('n', '<leader>R', '<Plug>(KsbRefresh)', {
      buffer = p.bufid,
      desc = 'My local refresh',
      silent = true,
      nowait = true,
    })
    require('kitty-scrollback.keymaps').set_scrollback_keymaps(p.bufid)

    for _ = 1, 2 do
      local oldbuf = p.bufid
      vim.cmd.normal(' R')
      assert.is_true(vim.wait(5000, function()
        return p.bufid ~= oldbuf and not p.refreshing
      end))
      local mapping = vim.fn.maparg('<leader>R', 'n', false, true)
      assert.equals('<Plug>(KsbRefresh)', mapping.rhs)
      assert.equals(1, mapping.buffer)
      assert.equals('My local refresh', mapping.desc)
      assert.equals(1, mapping.silent)
      assert.equals(1, mapping.nowait)
      assert.equals(0, vim.fn.maparg('<leader>r', 'n', false, true).buffer)
    end
  end)

  it('leaves refresh unmapped when default keymaps are disabled', function()
    vim.keymap.del('n', '<leader>r', { buffer = p.bufid })
    vim.keymap.del('n', '<Plug>(KsbRefresh)', { buffer = p.bufid })
    opts.keymaps_enabled = false
    require('kitty-scrollback.keymaps').set_scrollback_keymaps(p.bufid)
    assert.equals('', vim.fn.maparg('<leader>r', 'n'))
    assert.equals('', vim.fn.maparg('<Plug>(KsbRefresh)', 'n'))
    local oldbuf = p.bufid

    vim.cmd.KittyScrollbackRefresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.equals('', vim.fn.maparg('<leader>r', 'n'))
    assert.equals('', vim.fn.maparg('<Plug>(KsbRefresh)', 'n'))
  end)

  it('warns and restores the nearest line when the viewed text is gone', function()
    local added = {}
    for i = 101, 500 do
      table.insert(added, ('line %03d sample output'):format(i))
    end
    append(table.concat(added, '\n'))
    local oldbuf = p.bufid

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.equals(1, view()[1])
    assert.is_not_nil(lines()[1]:find('sample output', 1, true))
    assert.equals(vim.log.levels.WARN, notifications[1].level)
  end)

  it('keeps the old snapshot on a failed fetch and allows retrying', function()
    local messages = original_ui_send and record_presentation()
    local oldbuf = p.bufid
    local before_lines = lines()
    local before_view = view()
    p.kitty_data.window_id = 999999

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.refreshing == false
    end))
    assert.equals(oldbuf, p.bufid)
    assert.same(before_lines, lines())
    assert.same(before_view, view())
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
    if messages then
      assert.equals(0, #messages)
    end
    p.kitty_data.window_id = 1
    api.refresh()
    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
  end)

  it('preserves an open paste window and its edited contents', function()
    local util = require('kitty-scrollback.util')
    local windows = require('kitty-scrollback.windows')
    local autocommands = require('kitty-scrollback.autocommands')
    util.setup(p, opts)
    windows.setup(p, opts)
    autocommands.setup(p, opts)
    require('kitty-scrollback.footer_win').setup(p, opts)
    autocommands.load_autocmds()
    opts.paste_window.hide_footer = true
    p.pos = {
      cursor_line = 40,
      buf_last_line = #lines(),
      win_first_line = 30,
      win_last_line = 51,
      col = 8,
    }
    windows.open_paste_window()
    vim.api.nvim_buf_set_lines(p.paste_bufid, 0, -1, false, { 'draft command; do not execute' })
    local pastewin = p.paste_winid
    local oldbuf = p.bufid
    append('output while editing a draft')

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.is_true(vim.api.nvim_win_is_valid(pastewin))
    assert.equals(pastewin, vim.api.nvim_get_current_win())
    assert.same(
      { 'draft command; do not execute' },
      vim.api.nvim_buf_get_lines(p.paste_bufid, 0, -1, false)
    )
  end)

  it('keeps the same text in view after Kitty evicts older history', function()
    vim.fn.winrestview({ lnum = 90, col = 8, topline = 80 })
    local before = view()
    local cursor_text = lines()[before[1]]
    local top_text = lines()[before[3]]
    local added = {}
    for i = 101, 280 do
      table.insert(added, ('line %03d sample output'):format(i))
    end
    append(table.concat(added, '\n'))
    local oldbuf = p.bufid

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    local after = view()
    assert.equals(cursor_text, lines()[after[1]])
    assert.equals(top_text, lines()[after[3]])
    assert.equals(before[1] - before[3], after[1] - after[3])
    assert.equals(before[2], after[2])
  end)

  it('adds new output without moving the cursor or viewport', function()
    local before = view()
    local oldbuf = p.bufid
    append('new output after opening scrollback')

    api.refresh()

    assert.is_true(vim.wait(5000, function()
      return p.bufid ~= oldbuf
    end))
    assert.same(before, view())
    assert.is_not_nil(
      table.concat(lines(), '\n'):find('new output after opening scrollback', 1, true)
    )
    assert.is_false(vim.api.nvim_buf_is_valid(oldbuf))
  end)
end)
