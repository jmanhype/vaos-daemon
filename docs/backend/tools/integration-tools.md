# Integration Tools

Integration tools connect Daemon to the external world: the web, GitHub, git repositories, user interaction, and sub-agent delegation.

---

## `web_fetch`

Fetch a URL and extract text content. Optionally uses AI to extract specific information.

**Module:** `Daemon.Tools.Builtins.WebFetch`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `url` | string | yes | The URL to fetch |
| `prompt` | string | no | What to extract from the page (triggers AI extraction) |

### Behavior

- Validates URL scheme (`http`/`https` only) and blocks private IP ranges (localhost, 10.x, 172.16–31.x, 192.168.x, 169.254.x)
- Strips HTML tags, scripts, and styles before returning text
- Body is capped at 15KB
- When `prompt` is provided and the page has > 100 chars: calls the utility LLM model to extract specifically requested information
- Without `prompt`: returns raw stripped text

### SSRF protection

Private hosts are blocked at the IP level using `:inet.parse_address/1`. The following are rejected:
```
127.x.x.x, 10.x.x.x, 172.16-31.x.x, 192.168.x.x,
169.254.x.x (link-local), ::1, localhost, 0.0.0.0
```

### Example

```json
{"url": "https://hexdocs.pm/elixir/GenServer.html", "prompt": "list all callback functions"}
```

---

## `web_search`

Search the web using a configured search engine.

**Module:** `Daemon.Tools.Builtins.WebSearch`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Search query |
| `max_results` | integer | no | Maximum results to return (default: 5) |

Returns formatted search results with title, URL, and snippet for each result. Requires a search API key configured in application config.

---

## `github`

Interact with GitHub repositories via the GitHub API.

**Module:** `Daemon.Tools.Builtins.Github`
**Safety:** `:write_safe`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | yes | `list_repos`, `get_repo`, `list_issues`, `get_issue`, `create_issue`, `list_prs`, `get_pr`, `create_pr`, `list_files`, `get_file`, `search_code`, `create_branch`, `merge_pr` |
| `repo` | string | no | Repository in `owner/name` format |
| `issue_number` | integer | no | Issue or PR number |
| `title` | string | no | Issue/PR title |
| `body` | string | no | Issue/PR body |
| `head` | string | no | Head branch for PR |
| `base` | string | no | Base branch for PR |
| `query` | string | no | Search query for `search_code` |
| `path` | string | no | File path for `get_file` |
| `branch` | string | no | Branch name for `create_branch` |

Requires `GITHUB_TOKEN` environment variable or configured OAuth token. All API calls use the authenticated GitHub REST API.

---

## `git`

Run git operations in a repository. Safe — executes specific git subcommands only, no arbitrary shell.

**Module:** `Daemon.Tools.Builtins.Git`
**Safety:** `:write_destructive`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `operation` | string | yes | Git operation name |
| `path` | string | no | Working directory (default: `~/.daemon/workspace`) |
| `message` | string | no | Commit message |
| `file` | string | no | File path for diff/blame |
| `files` | array | no | Files to stage for `add` |
| `count` | integer | no | Log entries to show |
| `format` | string | no | Log format: `oneline`, `full`, `conventional` |
| `remote` | string | no | Remote name (default: `origin`) |
| `branch_name` | string | no | Branch name to create/switch |
| `ref` | string | no | Git ref or commit hash |
| `tag_name` | string | no | Tag name |
| `tag_action` | string | no | `list`, `create`, `delete`, `push`, `latest` |
| `stash_action` | string | no | `push`, `pop`, `list`, `drop` |
| `reset_mode` | string | no | `soft`, `mixed`, `hard` |
| `since` | string | no | Show commits since this ref/tag |

### Supported operations

| Operation | Description |
|-----------|-------------|
| `status` | Short status + branch info |
| `diff` | Show unstaged/staged changes (optionally for a single file) |
| `log` | Commit history with `oneline`/`full`/`conventional` format |
| `commit` | Stage all (`git add -A`) and commit with message |
| `add` | Stage files (all if no `files` given) |
| `push` | Push to remote, optionally set upstream |
| `pull` | Pull from remote |
| `clone` | Clone a repository into `~/.daemon/workspace/<repo-name>` |
| `branch` | List branches or create/switch + push new branch |
| `show` | Show commit details for a ref (default: HEAD) |
| `stash` | Push/pop/list/drop stash |
| `reset` | Reset HEAD with soft/mixed/hard mode |
| `remote` | List remotes or add a new one |
| `tag` | List/create/delete/push tags, get latest semver tag |
| `blame` | Line authorship with optional line range |
| `search` | Search commit messages (grep) and/or code changes (pickaxe) |
| `cherry_pick` | Apply commits to current branch |
| `worktree` | List/add/remove git worktrees |
| `bisect` | Binary search for bug-introducing commits |
| `reflog` | Show recent HEAD history |
| `pr_diff` | Show diff from base branch to HEAD |

### Conventional log format

The `conventional` log format groups commits by type for changelog generation:
```
### Features
- feat(auth): add JWT refresh tokens

### Bug Fixes
- fix(api): handle null user gracefully

### Chore
- chore: update dependencies
```

### Auto-init

If `path` is not a git repository, the tool initializes it automatically with `git init` and sets minimal local `user.name`/`user.email` config so commits work without global git config.

### Bisect safety

The `bisect run` action only allows a whitelist of executables:
```
mix, elixir, cargo, go, npm, yarn, pytest, python, python3, ruby, bash, sh
```

### Clone URL validation

Only `http://`, `https://`, `git://`, and `ssh://` schemes are accepted for clone to prevent SSRF attacks.

---

## `ask_user`

Prompt the user for input during agent execution.

**Module:** `Daemon.Tools.Builtins.AskUser`
**Safety:** `:read_only`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `question` | string | yes | Question to ask the user |
| `options` | array | no | List of option strings for multiple-choice input |
| `timeout_ms` | integer | no | Milliseconds to wait for response (default: 300,000) |

### Behavior

Suspends the agent loop and emits an `:ask_user` event on the event bus. The CLI or HTTP channel surfaces the question to the user. The agent waits for a response or the timeout.

When `options` is provided, the user sees a numbered menu. Free-text input is always accepted regardless.

Returns the user's response as a string, or `"(no response — timeout)"` if the timeout elapses.

---

## `delegate`

Spawn a focused research sub-agent that autonomously completes a scoped task.

**Module:** `Daemon.Tools.Builtins.Delegate`

See [Delegation](../orchestration/delegation.md) for full documentation.

---

## See Also

- [Tools Overview](./overview.md)
- [File Tools](./file-tools.md)
- [Orchestration — Delegation](../orchestration/delegation.md)
