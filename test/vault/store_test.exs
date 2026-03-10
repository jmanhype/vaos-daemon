defmodule OptimalSystemAgent.Vault.StoreTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Vault.Store

  setup do
    tmp = System.tmp_dir!() |> Path.join("vault_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "vault_root/0" do
    test "returns path under config_dir", %{tmp: tmp} do
      root = Store.vault_root()
      assert root == Path.join(tmp, "vault")
    end
  end

  describe "init/0" do
    test "creates all category directories", %{tmp: tmp} do
      assert :ok = Store.init()
      root = Path.join(tmp, "vault")

      for dir <- ~w(facts decisions lessons preferences commitments relationships projects observations) do
        assert File.dir?(Path.join(root, dir))
      end
    end

    test "creates internal directories", %{tmp: tmp} do
      Store.init()
      root = Path.join(tmp, "vault")

      assert File.dir?(Path.join(root, ".vault"))
      assert File.dir?(Path.join([root, ".vault", "checkpoints"]))
      assert File.dir?(Path.join([root, ".vault", "dirty"]))
    end

    test "creates handoffs directory", %{tmp: tmp} do
      Store.init()
      assert File.dir?(Path.join([tmp, "vault", "handoffs"]))
    end
  end

  describe "write/4" do
    test "writes a markdown file and returns path" do
      Store.init()
      assert {:ok, path} = Store.write(:fact, "Test Fact", "This is a test fact.")
      assert File.exists?(path)
      assert String.ends_with?(path, "test-fact.md")
    end

    test "file contains frontmatter and content" do
      Store.init()
      {:ok, path} = Store.write(:decision, "Use Elixir", "We chose Elixir for the backend.",
        %{"context" => "backend rewrite", "outcome" => "elixir"})

      content = File.read!(path)
      assert content =~ "category: decision"
      assert content =~ "context: backend rewrite"
      assert content =~ "outcome: elixir"
      assert content =~ "# Use Elixir"
      assert content =~ "We chose Elixir for the backend."
    end

    test "slugifies title for filename" do
      Store.init()
      {:ok, path} = Store.write(:fact, "Hello World! Special (chars)", "content")
      basename = Path.basename(path)
      refute basename =~ "!"
      refute basename =~ "("
      assert basename =~ "hello-world"
    end

    test "creates category dir if it does not exist" do
      # Don't call init, let write create the dir
      assert {:ok, _path} = Store.write(:fact, "Auto Dir", "content")
    end
  end

  describe "read/1" do
    test "reads file and parses frontmatter" do
      Store.init()
      {:ok, path} = Store.write(:lesson, "Caching Helps", "Caching reduces latency significantly.")

      assert {:ok, meta, body} = Store.read(path)
      assert meta["category"] == "lesson"
      assert body =~ "Caching Helps"
      assert body =~ "Caching reduces latency significantly."
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Store.read("/nonexistent/path.md")
    end
  end

  describe "list/1" do
    test "lists markdown files in category" do
      Store.init()
      Store.write(:fact, "Fact One", "content one")
      Store.write(:fact, "Fact Two", "content two")

      files = Store.list(:fact)
      assert length(files) == 2
      assert Enum.all?(files, &String.ends_with?(&1, ".md"))
    end

    test "returns empty list for empty category" do
      Store.init()
      assert Store.list(:project) == []
    end

    test "returns empty list if directory does not exist" do
      # No init, so dirs don't exist
      assert Store.list(:commitment) == []
    end

    test "returns sorted list" do
      Store.init()
      Store.write(:lesson, "B Lesson", "b")
      Store.write(:lesson, "A Lesson", "a")

      files = Store.list(:lesson)
      basenames = Enum.map(files, &Path.basename/1)
      assert basenames == Enum.sort(basenames)
    end
  end

  describe "search/2" do
    test "finds files matching query" do
      Store.init()
      Store.write(:fact, "Elixir Version", "Elixir runs on the BEAM virtual machine.")
      Store.write(:fact, "Python Info", "Python is a scripting language.")
      Store.write(:decision, "Use BEAM", "We chose BEAM for concurrency.")

      results = Store.search("BEAM")
      assert length(results) >= 1
      assert Enum.all?(results, fn {_cat, _path, score} -> score > 0 end)
    end

    test "returns empty list when nothing matches" do
      Store.init()
      Store.write(:fact, "Elixir", "The language we use.")

      results = Store.search("zzznonexistentzzzz")
      assert results == []
    end

    test "respects categories filter" do
      Store.init()
      Store.write(:fact, "BEAM Fact", "BEAM is great.")
      Store.write(:decision, "BEAM Decision", "We chose BEAM.")

      results = Store.search("BEAM", categories: [:decision])
      assert Enum.all?(results, fn {cat, _, _} -> cat == :decision end)
    end

    test "respects limit option" do
      Store.init()

      for i <- 1..10 do
        Store.write(:fact, "Match #{i}", "searchable keyword content")
      end

      results = Store.search("searchable", limit: 3)
      assert length(results) <= 3
    end

    test "case-insensitive search" do
      Store.init()
      Store.write(:fact, "Mixed Case", "Elixir is GREAT for concurrency.")

      results = Store.search("elixir great")
      assert length(results) >= 1
    end
  end

  describe "delete/1" do
    test "deletes existing file" do
      Store.init()
      {:ok, path} = Store.write(:fact, "To Delete", "gone soon")
      assert File.exists?(path)

      assert :ok = Store.delete(path)
      refute File.exists?(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Store.delete("/nonexistent/file.md")
    end
  end

  describe "list_all/0" do
    test "lists files across all categories" do
      Store.init()
      Store.write(:fact, "A Fact", "content")
      Store.write(:decision, "A Decision", "content")
      Store.write(:lesson, "A Lesson", "content")

      all = Store.list_all()
      assert length(all) >= 3
      categories = Enum.map(all, fn {cat, _path} -> cat end) |> Enum.uniq()
      assert :fact in categories
      assert :decision in categories
      assert :lesson in categories
    end
  end
end
