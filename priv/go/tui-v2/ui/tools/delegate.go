package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// DelegateRenderer renders lightweight subagent invocations.
//
// Example:
//
//	✓ Delegate  summarise-codebase                  1.2s
//	  │ Found 12 files across 3 packages...
type DelegateRenderer struct{}

// Render implements ToolRenderer.
func (DelegateRenderer) Render(name, args, result string, opts RenderOpts) string {
	// Extract task from args JSON
	var parsed struct {
		Task string `json:"task"`
		Tier string `json:"tier"`
	}
	_ = json.Unmarshal([]byte(args), &parsed)
	task := parsed.Task
	if task == "" {
		task = "subagent task"
	}
	if len(task) > 80 {
		task = task[:77] + "..."
	}

	header := renderToolHeader(opts.Status, "Delegate", task, opts)

	if opts.Compact {
		return header
	}

	// Show result summary for completed delegates
	var body string
	if opts.Status == ToolSuccess && result != "" {
		if opts.Expanded {
			body = "\n" + renderToolBox(toolOutputPlainContent(result, 0, true), opts.Width)
		} else {
			// Show compact summary
			lines := strings.Split(strings.TrimSpace(result), "\n")
			preview := ""
			if len(lines) > 0 {
				preview = lines[0]
				if len(preview) > 100 {
					preview = preview[:97] + "..."
				}
			}
			if len(lines) > 1 {
				preview += fmt.Sprintf(" (%d more lines)", len(lines)-1)
			}
			body = "\n" + renderToolBox(style.Faint.Render(preview), opts.Width)
		}
	} else if opts.Status == ToolError && result != "" {
		body = "\n" + renderToolBox(style.ErrorText.Render(truncateLines(result, 3)), opts.Width)
	}

	return header + body
}
