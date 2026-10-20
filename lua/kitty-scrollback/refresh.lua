local M = {}

local function translate_line(line, hunks, last_line)
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local start, removed, added_start, added = hunk[1], hunk[2], hunk[3], hunk[4]
    if line < start or (removed == 0 and line == start) then
      break
    end
    if removed > 0 and line < start + removed then
      return math.max(1, math.min(last_line, added_start)), true
    end
    offset = offset + added - removed
  end
  return math.max(1, math.min(last_line, line + offset)), false
end

---@param p KsbPrivate|nil
---@param opts KsbOpts
M.refresh = function(p, opts)
  if not p or not p.bufid or not vim.api.nvim_buf_is_valid(p.bufid) then
    vim.notify('kitty-scrollback.nvim: no scrollback buffer to refresh', vim.log.levels.WARN)
    return
  end
  if p.refreshing then
    return
  end
  local oldbuf = assert(p.bufid)
  local cmd = {
    p.kitty_data.kitty_path,
    '@',
    'get-text',
    '--match=id:' .. p.kitty_data.window_id,
    '--extent=' .. opts.kitty_get_text.extent,
    '--add-wrap-markers',
  }
  if opts.kitty_get_text.ansi then
    table.insert(cmd, '--ansi')
  end
  if opts.kitty_get_text.clear_selection then
    table.insert(cmd, '--clear-selection')
  end

  p.refreshing = true
  local function failed(message)
    p.refreshing = false
    vim.notify('kitty-scrollback.nvim: refresh failed: ' .. message, vim.log.levels.ERROR)
  end
  local started, err = pcall(
    vim.system,
    cmd,
    { timeout = 10000 },
    vim.schedule_wrap(function(result)
      if p.bufid ~= oldbuf or not vim.api.nvim_buf_is_valid(oldbuf) then
        p.refreshing = false
        return
      end
      if result.code ~= 0 then
        failed(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'get-text failed')
        return
      end
      local windows = vim.fn.win_findbuf(oldbuf)
      if #windows == 0 then
        p.refreshing = false
        return
      end
      local columns = vim.o.columns
      local oldwin, oldpos = p.winid, p.pos
      local views, window_options = {}, {}
      local function save_window(win)
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        window_options[win] = {}
        for name, info in pairs(vim.api.nvim_get_all_options_info()) do
          if info.scope == 'win' then
            window_options[win][name] =
              vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
          end
        end
      end
      local function restore_window(win, saved)
        for name, value in pairs(window_options[win]) do
          if vim.api.nvim_get_option_value(name, { win = win, scope = 'local' }) ~= value then
            vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' })
          end
        end
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(saved)
        end)
      end
      for _, win in ipairs(windows) do
        save_window(win)
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].scrollback = vim.bo[oldbuf].scrollback
      local render_win
      local channel
      local function discard()
        vim.o.columns = columns
        for win, saved in pairs(views) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(oldbuf) then
            if vim.api.nvim_win_get_buf(win) == buf then
              vim.api.nvim_win_set_buf(win, oldbuf)
            end
            if vim.api.nvim_win_get_buf(win) == oldbuf then
              restore_window(win, saved)
            end
          end
        end
        if p.bufid == buf then
          p.bufid, p.winid, p.pos = oldbuf, oldwin, oldpos
        end
        if render_win and vim.api.nvim_win_is_valid(render_win) then
          vim.api.nvim_win_close(render_win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        p.refreshing = false
      end
      local function finish()
        if not vim.api.nvim_buf_is_valid(buf) then
          discard()
          return
        end
        windows = vim.fn.win_findbuf(oldbuf)
        if p.bufid ~= oldbuf or not vim.api.nvim_buf_is_valid(oldbuf) or #windows == 0 then
          discard()
          return
        end
        -- Freeze the snapshot before resizing it into the reading window, preserving wide lines.
        vim.fn.chanclose(channel)
        vim.o.columns = columns
        local prepared, hunks = pcall(function()
          if opts.scrollback_tempfile then
            local filename, ok =
              require('kitty-scrollback.util').create_tempfile(buf, vim.api.nvim_buf_get_name(buf))
            assert(ok, 'could not write scrollback temporary file')
            vim.api.nvim_buf_set_name(buf, filename)
          end
          -- shortcut: repeated identical lines can align ambiguously; use stable line IDs if Kitty exposes them.
          local diff = vim.text and vim.text.diff or rawget(vim, 'diff')
          return diff(
            table.concat(vim.api.nvim_buf_get_lines(oldbuf, 0, -1, false), '\n') .. '\n',
            table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n',
            { result_type = 'indices', algorithm = 'histogram' }
          )
        end)
        if not prepared then
          discard()
          failed(tostring(hunks))
          return
        end
        vim.api.nvim_win_close(render_win, true)
        local lost_position = false
        for _, win in ipairs(windows) do
          if not views[win] then
            save_window(win)
          end
          local saved = vim.deepcopy(views[win])
          local changed
          saved.lnum, changed = translate_line(saved.lnum, hunks, vim.api.nvim_buf_line_count(buf))
          saved.topline = translate_line(saved.topline, hunks, vim.api.nvim_buf_line_count(buf))
          lost_position = lost_position or changed
          -- Keep p.bufid unchanged so BufEnter does not close the paste window.
          vim.api.nvim_win_set_buf(win, buf)
          restore_window(win, saved)
        end
        p.bufid = buf
        p.winid = windows[1]
        p.pos = vim.api.nvim_win_call(p.winid, function()
          return {
            cursor_line = vim.fn.line('.'),
            buf_last_line = vim.fn.line('$'),
            win_first_line = vim.fn.line('w0'),
            win_last_line = vim.fn.line('w$'),
            col = vim.fn.wincol() - 1,
            view = vim.fn.winsaveview(),
          }
        end)
        local initialized, init_error = pcall(vim.api.nvim_buf_call, buf, function()
          -- Ex propagates FileType hook errors so the old snapshot can be restored.
          vim.cmd('setlocal filetype=kitty-scrollback')
          require('kitty-scrollback.keymaps').set_scrollback_keymaps(buf, oldbuf)
        end)
        if not initialized then
          discard()
          failed(tostring(init_error))
          return
        end
        require('kitty-scrollback.autocommands').set_term_enter_autocmd(buf)
        vim.api.nvim_buf_delete(oldbuf, { force = true })
        p.refreshing = false
        if lost_position then
          vim.notify(
            'kitty-scrollback.nvim: viewed text changed or left Kitty history; restored nearest position',
            vim.log.levels.WARN
          )
        end
      end
      local rendered, render_error = pcall(function()
        -- Floats are clamped to the editor width, so use the initial loader's temporary width.
        vim.o.columns = math.max(columns, opts.scrollback_columns)
        render_win = vim.api.nvim_open_win(buf, false, {
          relative = 'editor',
          row = 0,
          col = 0,
          width = math.max(opts.scrollback_columns, vim.api.nvim_win_get_width(windows[1])),
          height = vim.api.nvim_win_get_height(windows[1]),
          style = 'minimal',
          focusable = false,
          noautocmd = true,
          hide = true,
        })
        channel = vim.api.nvim_win_call(render_win, function()
          return vim.api.nvim_open_term(buf, {})
        end)
        local text = (result.stdout or ''):gsub('\r', ''):gsub('\n', '\27[0m\n')
        -- Terminal updates are deferred; restore the view only after rendered lines arrive.
        vim.api.nvim_buf_attach(buf, false, {
          on_lines = function()
            vim.schedule(finish)
            return true
          end,
        })
        -- Clearing marks the terminal dirty even when the snapshot contains only blank lines.
        vim.api.nvim_chan_send(channel, '\27[2J\27[H' .. text)
        vim.api.nvim_buf_set_name(buf, 'term://kitty-scrollback.nvim/' .. buf)
      end)
      if not rendered then
        discard()
        failed(tostring(render_error))
      end
    end)
  )
  if not started then
    failed(tostring(err))
  end
end

return M
