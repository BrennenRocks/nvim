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

local function open_comment_buffer(on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  vim.cmd("botright 5split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

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
        else
          local out = table.concat(stdout_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          local err = table.concat(stderr_chunks, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          vim.notify("Failed to post PR comment:\n" .. err .. "\n" .. out, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

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

return {}
