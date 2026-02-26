local ns = vim.api.nvim_create_namespace("gh-pr-comments")

-- Module-level cache: fetched once per nvim session
local cached_comments = nil
local fetch_in_progress = false
local refresh_signs_current

local function get_pr_context()
  local pr_number = vim.env.PR_NUMBER
  local repo_name = vim.env.REPO_NAME
  if not pr_number or not repo_name then
    return nil
  end
  return { pr_number = pr_number, repo_name = repo_name }
end

local function get_codediff_context()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return nil
  end

  local original_path, modified_path = lifecycle.get_paths(tabpage)
  local original_win, modified_win = lifecycle.get_windows(tabpage)
  local current_win = vim.api.nvim_get_current_win()

  local side = current_win == original_win and "LEFT" or "RIGHT"

  -- Always use original_path — it's consistently the git-relative path.
  -- modified_path can be an absolute filesystem path for working tree buffers.
  return { side = side, file_path = original_path }
end

local function open_comment_buffer(on_submit, initial_lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  vim.cmd("botright 5split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines or { "" })

  vim.keymap.set("n", "<C-s>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local comment = table.concat(lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    vim.cmd("close")
    if comment ~= "" then
      on_submit(comment)
    end
  end, { buffer = buf, desc = "Submit PR comment" })

  vim.keymap.set("n", "q", function()
    vim.cmd("close")
  end, { buffer = buf, desc = "Cancel PR comment" })

  vim.cmd("startinsert")
end

local function post_comment(pr, diff, start_line, end_line, comment)
  local commit_sha = vim.fn.system("git rev-parse HEAD"):gsub("%s+", "")

  local cmd = {
    "gh",
    "api",
    string.format("repos/%s/pulls/%s/comments", pr.repo_name, pr.pr_number),
    "-f",
    "body=" .. comment,
    "-f",
    "commit_id=" .. commit_sha,
    "-f",
    "path=" .. diff.file_path,
    "-f",
    "side=" .. diff.side,
    "-F",
    "line=" .. end_line,
  }

  if start_line ~= end_line then
    table.insert(cmd, "-F")
    table.insert(cmd, "start_line=" .. start_line)
    table.insert(cmd, "-f")
    table.insert(cmd, "start_side=" .. diff.side)
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          vim.notify("PR comment posted", vim.log.levels.INFO)
          -- Add the new comment to the cache and refresh signs
          local raw = table.concat(stdout_chunks, "\n")
          local ok, new_comment = pcall(vim.json.decode, raw)
          if ok and type(new_comment) == "table" and new_comment.id then
            if cached_comments then
              table.insert(cached_comments, new_comment)
            else
              cached_comments = { new_comment }
            end
            refresh_signs_current()
          end
        else
          local out = table.concat(stdout_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          local err = table.concat(stderr_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          vim.notify("Failed to post PR comment:\n" .. err .. "\n" .. out, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

--- Fetch all PR review comments and cache them.
--- Calls `on_done(comments)` when complete (or immediately if already cached).
local function fetch_comments(pr, on_done)
  if cached_comments then
    on_done(cached_comments)
    return
  end
  if fetch_in_progress then
    return
  end
  fetch_in_progress = true

  local stdout_chunks = {}
  vim.fn.jobstart({
    "gh",
    "api",
    string.format("repos/%s/pulls/%s/comments", pr.repo_name, pr.pr_number),
    "--paginate",
    "--slurp",
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      fetch_in_progress = false
      vim.schedule(function()
        if exit_code ~= 0 then
          return
        end
        local raw = table.concat(stdout_chunks, "\n")
        local ok, parsed = pcall(vim.json.decode, raw)
        if not ok or type(parsed) ~= "table" then
          return
        end
        -- --slurp with --paginate produces an array of arrays; flatten it
        local flat = {}
        for _, item in ipairs(parsed) do
          if type(item) == "table" and item.id then
            table.insert(flat, item)
          elseif type(item) == "table" then
            for _, c in ipairs(item) do
              if type(c) == "table" and c.id then
                table.insert(flat, c)
              end
            end
          end
        end
        cached_comments = flat
        on_done(cached_comments)
      end)
    end,
  })
end

--- Filter cached comments for a specific file path.
local function comments_for_file(path)
  if not cached_comments then
    return {}
  end
  local result = {}
  for _, c in ipairs(cached_comments) do
    if c.path == path then
      table.insert(result, c)
    end
  end
  return result
end

--- Place gutter signs on the appropriate diff buffers for the given file.
local function place_signs(tabpage, file_path)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  local original_bufnr, modified_bufnr = lifecycle.get_buffers(tabpage)
  if not original_bufnr or not modified_bufnr then
    return
  end

  -- Clear previous signs on both buffers
  if vim.api.nvim_buf_is_valid(original_bufnr) then
    vim.api.nvim_buf_clear_namespace(original_bufnr, ns, 0, -1)
  end
  if vim.api.nvim_buf_is_valid(modified_bufnr) then
    vim.api.nvim_buf_clear_namespace(modified_bufnr, ns, 0, -1)
  end

  local file_comments = comments_for_file(file_path)
  for _, c in ipairs(file_comments) do
    local line = c.line
    if type(line) == "number" and line >= 1 then
      local bufnr = (c.side == "LEFT") and original_bufnr or modified_bufnr
      if vim.api.nvim_buf_is_valid(bufnr) then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line <= line_count then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line - 1, 0, {
            sign_text = "◆",
            sign_hl_group = "DiagnosticSignInfo",
            priority = 150,
          })
        end
      end
    end
  end
end

--- Format a timestamp like "2024-01-15T10:30:00Z" into "Jan 15, 2024"
local function format_timestamp(ts)
  if not ts or type(ts) ~= "string" then
    return ""
  end
  local y, m, d = ts:match("^(%d+)-(%d+)-(%d+)")
  if not y then
    return ts
  end
  local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
  local month_name = months[tonumber(m)] or m
  return string.format("%s %d, %s", month_name, tonumber(d), y)
end

--- Update an existing comment via the GitHub API.
local function update_comment(pr, comment_id, new_body, on_done)
  local stdout_chunks = {}
  local stderr_chunks = {}
  vim.fn.jobstart({
    "gh",
    "api",
    "-X",
    "PATCH",
    string.format("repos/%s/pulls/comments/%s", pr.repo_name, comment_id),
    "-f",
    "body=" .. new_body,
  }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          vim.notify("Comment updated", vim.log.levels.INFO)
          local raw = table.concat(stdout_chunks, "\n")
          local ok, updated = pcall(vim.json.decode, raw)
          if ok and type(updated) == "table" and updated.id and cached_comments then
            for i, c in ipairs(cached_comments) do
              if c.id == updated.id then
                cached_comments[i] = updated
                break
              end
            end
          end
          if on_done then
            on_done()
          end
        else
          local err = table.concat(stderr_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          vim.notify("Failed to update comment:\n" .. err, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

--- Delete a comment via the GitHub API.
local function delete_comment(pr, comment_id, on_done)
  local stderr_chunks = {}
  vim.fn.jobstart({
    "gh",
    "api",
    "-X",
    "DELETE",
    string.format("repos/%s/pulls/comments/%s", pr.repo_name, comment_id),
  }, {
    stderr_buffered = true,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          vim.notify("Comment deleted", vim.log.levels.INFO)
          if cached_comments then
            for i, c in ipairs(cached_comments) do
              if c.id == comment_id then
                table.remove(cached_comments, i)
                break
              end
            end
          end
          if on_done then
            on_done()
          end
        else
          local err = table.concat(stderr_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          vim.notify("Failed to delete comment:\n" .. err, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

--- Collect all comments (roots + replies) on a given line/side, in display order.
local function comments_on_line(file_path, cursor_line, side)
  local file_comments = comments_for_file(file_path)
  local roots = {}
  local replies_by_root = {}
  for _, c in ipairs(file_comments) do
    if not c.in_reply_to_id and c.line == cursor_line and c.side == side then
      table.insert(roots, c)
      replies_by_root[c.id] = {}
    end
  end
  for _, c in ipairs(file_comments) do
    if c.in_reply_to_id and replies_by_root[c.in_reply_to_id] then
      table.insert(replies_by_root[c.in_reply_to_id], c)
    end
  end
  -- Flatten into ordered list
  local all = {}
  for _, root in ipairs(roots) do
    table.insert(all, root)
    for _, reply in ipairs(replies_by_root[root.id] or {}) do
      table.insert(all, reply)
    end
  end
  return all, roots, replies_by_root
end

--- Pick a comment from a list via vim.ui.select, or act immediately if only one.
local function pick_comment(comment_list, prompt, callback)
  if #comment_list == 0 then
    vim.notify("No comments on this line", vim.log.levels.INFO)
    return
  end
  if #comment_list == 1 then
    callback(comment_list[1])
    return
  end
  vim.ui.select(comment_list, {
    prompt = prompt,
    format_item = function(c)
      local user = (c.user and c.user.login) or "unknown"
      local preview = c.body:gsub("\n", " ")
      if #preview > 60 then
        preview = preview:sub(1, 57) .. "..."
      end
      return string.format("@%s: %s", user, preview)
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

--- Refresh signs for the current file.
refresh_signs_current = function()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local file_path = lifecycle.get_paths(tabpage)
  if file_path then
    place_signs(tabpage, file_path)
  end
end

--- Reply to a review comment thread via the GitHub API.
local function reply_to_comment(pr, root_comment_id, body)
  local stdout_chunks = {}
  local stderr_chunks = {}
  vim.fn.jobstart({
    "gh",
    "api",
    string.format("repos/%s/pulls/%s/comments", pr.repo_name, pr.pr_number),
    "-f",
    "body=" .. body,
    "-F",
    "in_reply_to=" .. root_comment_id,
  }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code == 0 then
          vim.notify("Reply posted", vim.log.levels.INFO)
          local raw = table.concat(stdout_chunks, "\n")
          local ok, new_comment = pcall(vim.json.decode, raw)
          if ok and type(new_comment) == "table" and new_comment.id then
            if cached_comments then
              table.insert(cached_comments, new_comment)
            else
              cached_comments = { new_comment }
            end
            refresh_signs_current()
          end
        else
          local err = table.concat(stderr_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          local out = table.concat(stdout_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          vim.notify("Failed to post reply:\n" .. err .. "\n" .. out, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

--- Open the comment actions menu for the current cursor line.
local function open_comment_menu()
  local pr = get_pr_context()
  if not pr then
    vim.notify("No PR context. Launch via gh-dash keybinding.", vim.log.levels.WARN)
    return
  end
  local diff = get_codediff_context()
  if not diff then
    vim.notify("Not in a CodeDiff session.", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.fn.line(".")
  local all_comments, roots, replies_by_root = comments_on_line(diff.file_path, cursor_line, diff.side)

  -- Build display lines
  local lines = {}
  if #all_comments == 0 then
    table.insert(lines, "No comments on this line")
  else
    for i, root in ipairs(roots) do
      if i > 1 then
        table.insert(lines, string.rep("─", 40))
      end
      local user = (root.user and root.user.login) or "unknown"
      table.insert(lines, string.format("@%s  (%s)", user, format_timestamp(root.created_at)))
      for body_line in root.body:gmatch("[^\n]*") do
        table.insert(lines, body_line)
      end
      for _, reply in ipairs(replies_by_root[root.id] or {}) do
        table.insert(lines, "")
        local reply_user = (reply.user and reply.user.login) or "unknown"
        table.insert(lines, string.format("  @%s  (%s)", reply_user, format_timestamp(reply.created_at)))
        for body_line in reply.body:gmatch("[^\n]*") do
          table.insert(lines, "  " .. body_line)
        end
      end
    end
  end
  table.insert(lines, "")
  table.insert(lines, "c: comment  r: reply  u: update  d: delete  q: close")

  -- Compute float dimensions
  local max_width = 20
  for _, l in ipairs(lines) do
    if #l > max_width then
      max_width = #l
    end
  end
  max_width = math.min(max_width + 2, math.floor(vim.o.columns * 0.8))
  local max_height = math.min(#lines, math.floor(vim.o.lines * 0.6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = max_width,
    height = max_height,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].scrollbind = false
  vim.wo[win].cursorbind = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- q / Esc: close
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })

  -- c: leave a new comment on this line
  vim.keymap.set("n", "c", function()
    close()
    open_comment_buffer(function(body)
      post_comment(pr, diff, cursor_line, cursor_line, body)
    end)
  end, { buffer = buf })

  -- r: reply to an existing thread
  vim.keymap.set("n", "r", function()
    close()
    if #roots == 0 then
      vim.notify("No comment threads on this line to reply to", vim.log.levels.INFO)
      return
    end
    pick_comment(roots, "Select thread to reply to:", function(root)
      open_comment_buffer(function(body)
        reply_to_comment(pr, root.id, body)
      end)
    end)
  end, { buffer = buf })

  -- u: update an existing comment
  vim.keymap.set("n", "u", function()
    close()
    pick_comment(all_comments, "Select comment to update:", function(comment)
      -- Pre-fill the edit buffer with the existing body
      local edit_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[edit_buf].filetype = "markdown"
      vim.bo[edit_buf].bufhidden = "wipe"

      vim.cmd("botright 5split")
      local edit_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(edit_win, edit_buf)
      vim.wo[edit_win].scrollbind = false
      vim.wo[edit_win].cursorbind = false

      local existing_lines = vim.split(comment.body, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, existing_lines)

      vim.keymap.set("n", "<C-s>", function()
        local new_lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
        local new_body = table.concat(new_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        vim.cmd("close")
        if new_body ~= "" then
          update_comment(pr, comment.id, new_body, refresh_signs_current)
        end
      end, { buffer = edit_buf, desc = "Submit updated comment" })

      vim.keymap.set("n", "q", function()
        vim.cmd("close")
      end, { buffer = edit_buf, desc = "Cancel edit" })
    end)
  end, { buffer = buf })

  -- d: delete a comment
  vim.keymap.set("n", "d", function()
    close()
    pick_comment(all_comments, "Select comment to delete:", function(comment)
      local user = (comment.user and comment.user.login) or "unknown"
      local preview = comment.body:gsub("\n", " ")
      if #preview > 50 then
        preview = preview:sub(1, 47) .. "..."
      end
      vim.ui.select({ "Yes", "No" }, {
        prompt = string.format('Delete @%s\'s comment: "%s"?', user, preview),
      }, function(choice)
        if choice == "Yes" then
          delete_comment(pr, comment.id, refresh_signs_current)
        end
      end)
    end)
  end, { buffer = buf })
end

-- ── Autocmds ──────────────────────────────────────────────────────

-- Fetch comments when CodeDiff opens (if PR env vars are set)
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffOpen",
  callback = function(args)
    local pr = get_pr_context()
    if not pr then
      return
    end
    local tabpage = args.data.tabpage
    fetch_comments(pr, function(comments)
      if not comments or #comments == 0 then
        return
      end
      -- Place signs for the initially-selected file
      local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
      if not ok then
        return
      end
      local file_path = lifecycle.get_paths(tabpage)
      if file_path then
        vim.defer_fn(function()
          place_signs(tabpage, file_path)
        end, 300)
      end
    end)
  end,
})

-- Place signs when a new file is selected in the explorer
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffFileSelect",
  callback = function(args)
    if not cached_comments then
      return
    end
    local tabpage = args.data.tabpage
    local file_path = args.data.path
    if not file_path then
      return
    end
    vim.defer_fn(function()
      place_signs(tabpage, file_path)
    end, 300)
  end,
})

-- ── Keybindings ───────────────────────────────────────────────────

-- Visual mode: post a new comment (existing)
vim.keymap.set("v", "<leader>gc", function()
  local pr = get_pr_context()
  if not pr then
    vim.notify("No PR context. Launch via gh-dash keybinding.", vim.log.levels.WARN)
    return
  end

  local diff = get_codediff_context()
  if not diff then
    vim.notify("Not in a CodeDiff session.", vim.log.levels.WARN)
    return
  end

  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  -- Exit visual mode before opening the comment buffer
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  open_comment_buffer(function(comment)
    post_comment(pr, diff, start_line, end_line, comment)
  end)
end, { desc = "Post PR review comment" })

-- Normal mode: PR comment actions menu
vim.keymap.set("n", "<leader>gC", open_comment_menu, { desc = "PR comment actions" })

-- Refresh comments from GitHub
vim.keymap.set("n", "<leader>gR", function()
  local pr = get_pr_context()
  if not pr then
    vim.notify("No PR context.", vim.log.levels.WARN)
    return
  end
  cached_comments = nil
  fetch_comments(pr, function(comments)
    vim.notify(string.format("Refreshed: %d comments", #comments), vim.log.levels.INFO)
    refresh_signs_current()
  end)
end, { desc = "Refresh PR comments" })

-- Jump to next/previous comment — uses cached_comments + codediff context
-- rather than extmarks (which can be cleared by other operations).
local function get_comment_lines()
  local diff = get_codediff_context()
  if not diff then
    return nil
  end
  local file_comments = comments_for_file(diff.file_path)
  local seen = {}
  local lines = {}
  for _, c in ipairs(file_comments) do
    if c.side == diff.side and c.line and c.line >= 1 and not seen[c.line] then
      seen[c.line] = true
      table.insert(lines, c.line)
    end
  end
  table.sort(lines)
  return lines
end

vim.keymap.set("n", "]g", function()
  local lines = get_comment_lines()
  if not lines or #lines == 0 then
    vim.notify("No comments in this buffer", vim.log.levels.INFO)
    return
  end
  local cursor_line = vim.fn.line(".")
  for _, line in ipairs(lines) do
    if line > cursor_line then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { lines[1], 0 })
end, { desc = "Next PR comment" })

vim.keymap.set("n", "[g", function()
  local lines = get_comment_lines()
  if not lines or #lines == 0 then
    vim.notify("No comments in this buffer", vim.log.levels.INFO)
    return
  end
  local cursor_line = vim.fn.line(".")
  for i = #lines, 1, -1 do
    if lines[i] < cursor_line then
      vim.api.nvim_win_set_cursor(0, { lines[i], 0 })
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { lines[#lines], 0 })
end, { desc = "Previous PR comment" })

-- Visual mode: suggest changes
vim.keymap.set("v", "<leader>gs", function()
  local pr = get_pr_context()
  if not pr then
    vim.notify("No PR context. Launch via gh-dash keybinding.", vim.log.levels.WARN)
    return
  end

  local diff = get_codediff_context()
  if not diff then
    vim.notify("Not in a CodeDiff session.", vim.log.levels.WARN)
    return
  end

  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  -- Get the selected lines from the buffer
  local selected = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  -- Build suggestion block
  local initial = { "```suggestion" }
  vim.list_extend(initial, selected)
  table.insert(initial, "```")

  -- Exit visual mode before opening the comment buffer
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  open_comment_buffer(function(comment)
    post_comment(pr, diff, start_line, end_line, comment)
  end, initial)
end, { desc = "Suggest code change" })

return {}
