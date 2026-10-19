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
local notifications

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
    if tempfile_stub then
      tempfile_stub:revert()
      tempfile_stub = nil
    end
    kitty_instance:kill(15)
    pcall(vim.keymap.del, 'n', '<leader>R')
    pcall(vim.keymap.del, 'n', '<leader>r')
    vim.cmd('silent! %bwipeout!')
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
