defmodule OptimalSystemAgent.Tools.Builtins.BrowserTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Browser

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns browser" do
      assert Browser.name() == "browser"
    end

    test "description is non-empty" do
      desc = Browser.description()
      assert is_binary(desc)
      assert String.length(desc) > 10
    end

    test "parameters returns valid JSON schema" do
      params = Browser.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "action")
      assert Map.has_key?(params["properties"], "url")
      assert Map.has_key?(params["properties"], "selector")
      assert Map.has_key?(params["properties"], "text")
      assert Map.has_key?(params["properties"], "script")
      assert params["required"] == ["action"]
    end

    test "action parameter lists valid enum values" do
      params = Browser.parameters()
      enum = params["properties"]["action"]["enum"]
      assert "navigate" in enum
      assert "get_text" in enum
      assert "get_html" in enum
      assert "screenshot" in enum
      assert "click" in enum
      assert "type" in enum
      assert "evaluate" in enum
      assert "close" in enum
    end

    test "available? returns true (always available via fallback)" do
      assert Browser.available?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter validation
  # ---------------------------------------------------------------------------

  describe "parameter validation" do
    test "missing action returns error" do
      assert {:error, msg} = Browser.execute(%{})
      assert msg =~ "Missing required parameter: action"
    end

    test "unknown action returns error" do
      assert {:error, msg} = Browser.execute(%{"action" => "explode"})
      assert msg =~ "Unknown action"
      assert msg =~ "explode"
    end

    test "navigate without url returns error" do
      # In fallback mode, navigate requires url
      assert {:error, msg} = Browser.execute(%{"action" => "navigate"})
      assert msg =~ "url"
    end

    test "navigate with empty url returns error" do
      assert {:error, msg} = Browser.execute(%{"action" => "navigate", "url" => ""})
      assert msg =~ "url"
    end
  end

  # ---------------------------------------------------------------------------
  # Fallback HTTP mode (no Playwright)
  # ---------------------------------------------------------------------------

  describe "fallback HTTP mode" do
    setup do
      # Force fallback mode by caching playwright as unavailable
      :persistent_term.put(
        {OptimalSystemAgent.Tools.Builtins.Browser, :playwright_available},
        false
      )

      on_exit(fn ->
        :persistent_term.erase({OptimalSystemAgent.Tools.Builtins.Browser, :playwright_available})
      end)
    end

    test "close action succeeds with fallback message" do
      assert {:ok, msg} = Browser.execute(%{"action" => "close"})
      assert msg =~ "fallback"
    end

    test "screenshot action returns playwright-required error" do
      assert {:error, msg} = Browser.execute(%{"action" => "screenshot"})
      assert msg =~ "Playwright"
    end

    test "click action returns playwright-required error" do
      assert {:error, msg} = Browser.execute(%{"action" => "click", "selector" => "#btn"})
      assert msg =~ "Playwright"
    end

    test "type action returns playwright-required error" do
      assert {:error, msg} =
               Browser.execute(%{"action" => "type", "selector" => "#input", "text" => "hello"})

      assert msg =~ "Playwright"
    end

    test "evaluate action returns playwright-required error" do
      assert {:error, msg} =
               Browser.execute(%{"action" => "evaluate", "script" => "1+1"})

      assert msg =~ "Playwright"
    end

    test "navigate with invalid URL returns error" do
      assert {:error, msg} = Browser.execute(%{"action" => "navigate", "url" => "not-a-url"})
      assert msg =~ "Invalid URL"
    end

    test "navigate with ftp URL returns error" do
      assert {:error, msg} =
               Browser.execute(%{"action" => "navigate", "url" => "ftp://example.com/file"})

      assert msg =~ "Invalid URL"
    end

    test "get_text without url returns error in fallback mode" do
      assert {:error, msg} = Browser.execute(%{"action" => "get_text"})
      assert msg =~ "url"
    end

    test "get_html without url returns error in fallback mode" do
      assert {:error, msg} = Browser.execute(%{"action" => "get_html"})
      assert msg =~ "url"
    end
  end

  # ---------------------------------------------------------------------------
  # HTML helpers (unit tests for internal parsing)
  # ---------------------------------------------------------------------------

  describe "extract_by_selector/2" do
    test "extracts element by id selector" do
      html = ~s(<div><p id="target">Hello world</p><p>Other</p></div>)
      result = Browser.extract_by_selector(html, "#target")
      assert result =~ "Hello world"
    end

    test "extracts element by class selector" do
      html = ~s(<div><span class="info highlight">Content here</span></div>)
      result = Browser.extract_by_selector(html, ".info")
      assert result =~ "Content here"
    end

    test "extracts element by tag selector" do
      html = ~s(<div><h1>Title</h1><p>Body</p></div>)
      result = Browser.extract_by_selector(html, "h1")
      assert result =~ "Title"
    end

    test "extracts element by tag#id selector" do
      html = ~s(<div><p id="main">Main text</p><p id="other">Other</p></div>)
      result = Browser.extract_by_selector(html, "p#main")
      assert result =~ "Main text"
    end

    test "extracts element by tag.class selector" do
      html = ~s(<ul><li class="active">First</li><li>Second</li></ul>)
      result = Browser.extract_by_selector(html, "li.active")
      assert result =~ "First"
    end

    test "returns empty string when selector not found" do
      html = ~s(<div><p>Hello</p></div>)
      result = Browser.extract_by_selector(html, "#nonexistent")
      assert result == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Playwright detection
  # ---------------------------------------------------------------------------

  describe "playwright_available?/0" do
    test "returns a boolean" do
      # Clear any cached value
      try do
        :persistent_term.erase({Browser, :playwright_available})
      rescue
        ArgumentError -> :ok
      end

      result = Browser.playwright_available?()
      assert is_boolean(result)
    end

    test "caches the result in persistent_term" do
      :persistent_term.put({Browser, :playwright_available}, true)
      assert Browser.playwright_available?() == true

      :persistent_term.put({Browser, :playwright_available}, false)
      assert Browser.playwright_available?() == false

      # Cleanup
      :persistent_term.erase({Browser, :playwright_available})
    end
  end
end
