defmodule OptimalSystemAgent.Signal.ClassifierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Signal.Classifier

  # ---------------------------------------------------------------------------
  # classify_fast/2 — full 5-tuple struct
  # ---------------------------------------------------------------------------

  describe "classify_fast/2" do
    test "returns a Classifier struct with all five dimensions populated" do
      signal = Classifier.classify_fast("create a dashboard")

      assert %Classifier{} = signal
      assert is_atom(signal.mode)
      assert is_atom(signal.genre)
      assert is_binary(signal.type)
      assert is_atom(signal.format)
      assert is_float(signal.weight)
    end

    test "stores the raw message verbatim" do
      raw = "analyze revenue trends for Q4"
      signal = Classifier.classify_fast(raw)

      assert signal.raw == raw
    end

    test "stores the channel" do
      signal = Classifier.classify_fast("hello", :telegram)

      assert signal.channel == :telegram
    end

    test "timestamp is a UTC DateTime" do
      signal = Classifier.classify_fast("test message")

      assert %DateTime{} = signal.timestamp
      assert signal.timestamp.time_zone == "Etc/UTC"
    end
  end

  # ---------------------------------------------------------------------------
  # Mode classification — Beer's VSM S1-S5
  # ---------------------------------------------------------------------------

  describe "mode classification" do
    test "BUILD: message containing 'create' maps to :build" do
      assert Classifier.classify_fast("create a dashboard").mode == :build
    end

    test "BUILD: message containing 'build' maps to :build" do
      assert Classifier.classify_fast("build a new API endpoint").mode == :build
    end

    test "BUILD: message containing 'generate' maps to :build" do
      assert Classifier.classify_fast("generate the migration files").mode == :build
    end

    test "BUILD: message containing 'make' maps to :build" do
      assert Classifier.classify_fast("make a new config file").mode == :build
    end

    test "BUILD: message containing 'scaffold' maps to :build" do
      assert Classifier.classify_fast("scaffold a Phoenix context").mode == :build
    end

    test "BUILD: message containing 'design' maps to :build" do
      assert Classifier.classify_fast("design the database schema").mode == :build
    end

    test "BUILD: message containing 'new' maps to :build" do
      assert Classifier.classify_fast("new project setup").mode == :build
    end

    test "EXECUTE: message containing 'run' maps to :execute" do
      assert Classifier.classify_fast("run the sync job").mode == :execute
    end

    test "EXECUTE: message containing 'execute' maps to :execute" do
      assert Classifier.classify_fast("execute the deployment script").mode == :execute
    end

    test "EXECUTE: message containing 'trigger' maps to :execute" do
      assert Classifier.classify_fast("trigger the webhook").mode == :execute
    end

    test "EXECUTE: message containing 'sync' maps to :execute" do
      assert Classifier.classify_fast("sync the remote database").mode == :execute
    end

    test "EXECUTE: message containing 'send' maps to :execute" do
      assert Classifier.classify_fast("send the report to Slack").mode == :execute
    end

    test "EXECUTE: message containing 'import' maps to :execute" do
      assert Classifier.classify_fast("import the CSV file").mode == :execute
    end

    test "EXECUTE: message containing 'export' maps to :execute" do
      assert Classifier.classify_fast("export data to JSON").mode == :execute
    end

    test "ANALYZE: message containing 'analyze' maps to :analyze" do
      assert Classifier.classify_fast("analyze revenue for last quarter").mode == :analyze
    end

    test "ANALYZE: message containing 'report' maps to :analyze" do
      assert Classifier.classify_fast("report on user growth").mode == :analyze
    end

    test "ANALYZE: message containing 'dashboard' maps to :analyze" do
      assert Classifier.classify_fast("open the metrics dashboard").mode == :analyze
    end

    test "ANALYZE: message containing 'metrics' maps to :analyze" do
      assert Classifier.classify_fast("show me the performance metrics").mode == :analyze
    end

    test "ANALYZE: message containing 'trend' maps to :analyze" do
      assert Classifier.classify_fast("what's the trend in signups?").mode == :analyze
    end

    test "ANALYZE: message containing 'compare' maps to :analyze" do
      assert Classifier.classify_fast("compare this week vs last week").mode == :analyze
    end

    test "ANALYZE: message containing 'kpi' maps to :analyze" do
      assert Classifier.classify_fast("kpi review for the team").mode == :analyze
    end

    test "MAINTAIN: message containing 'fix' maps to :maintain" do
      assert Classifier.classify_fast("fix the login bug").mode == :maintain
    end

    test "MAINTAIN: message containing 'update' maps to :maintain" do
      assert Classifier.classify_fast("update the dependencies").mode == :maintain
    end

    test "MAINTAIN: message containing 'migrate' maps to :maintain" do
      assert Classifier.classify_fast("migrate the database schema").mode == :maintain
    end

    test "MAINTAIN: message containing 'backup' maps to :maintain" do
      assert Classifier.classify_fast("backup the production database").mode == :maintain
    end

    test "MAINTAIN: message containing 'rollback' maps to :maintain" do
      assert Classifier.classify_fast("rollback the last deploy").mode == :maintain
    end

    test "MAINTAIN: message containing 'health' maps to :maintain" do
      assert Classifier.classify_fast("health check the services").mode == :maintain
    end

    test "MAINTAIN: message containing 'restore' maps to :maintain" do
      assert Classifier.classify_fast("restore from backup").mode == :maintain
    end

    test "ASSIST: unmatched message defaults to :assist" do
      assert Classifier.classify_fast("help me understand this").mode == :assist
    end

    test "ASSIST: generic conversational message maps to :assist" do
      assert Classifier.classify_fast("what time is it in Tokyo?").mode == :assist
    end

    test "mode matching is case-insensitive" do
      assert Classifier.classify_fast("CREATE a new table").mode == :build
      assert Classifier.classify_fast("RUN the tests").mode == :execute
      assert Classifier.classify_fast("ANALYZE the logs").mode == :analyze
      assert Classifier.classify_fast("FIX the crash").mode == :maintain
    end
  end

  # ---------------------------------------------------------------------------
  # Genre classification — Speech Act Theory
  # ---------------------------------------------------------------------------

  describe "genre classification" do
    test "DIRECT: message containing 'please' maps to :direct" do
      assert Classifier.classify_fast("please do the cleanup").genre == :direct
    end

    test "DIRECT: message containing 'do' maps to :direct" do
      assert Classifier.classify_fast("do a code review for me").genre == :direct
    end

    test "DIRECT: message containing 'run' maps to :direct" do
      assert Classifier.classify_fast("run the test suite").genre == :direct
    end

    test "DIRECT: message containing 'make' maps to :direct" do
      assert Classifier.classify_fast("make a new branch").genre == :direct
    end

    test "DIRECT: message ending with '!' maps to :direct" do
      assert Classifier.classify_fast("Deploy now!").genre == :direct
    end

    test "COMMIT: message containing 'i will' maps to :commit" do
      assert Classifier.classify_fast("I will handle the release").genre == :commit
    end

    test "COMMIT: message containing 'let me' maps to :commit" do
      assert Classifier.classify_fast("let me check the logs").genre == :commit
    end

    test "COMMIT: message containing 'i promise' maps to :commit" do
      assert Classifier.classify_fast("I promise to finish by Friday").genre == :commit
    end

    test "COMMIT: message containing 'i commit' maps to :commit" do
      assert Classifier.classify_fast("I commit to reviewing the PR today").genre == :commit
    end

    test "DECIDE: message containing 'approve' maps to :decide" do
      assert Classifier.classify_fast("approve the deployment").genre == :decide
    end

    test "DECIDE: message containing 'reject' maps to :decide" do
      assert Classifier.classify_fast("reject the proposal").genre == :decide
    end

    test "DECIDE: message containing 'confirm' maps to :decide" do
      assert Classifier.classify_fast("confirm the release").genre == :decide
    end

    test "DECIDE: message containing 'cancel' maps to :decide" do
      assert Classifier.classify_fast("cancel the job").genre == :decide
    end

    test "DECIDE: message containing 'set' maps to :decide" do
      assert Classifier.classify_fast("set flag to true").genre == :decide
    end

    test "DECIDE: 'set' does not match as substring inside other words" do
      # "reset" contains "set" but word-boundary matching prevents false match
      assert Classifier.classify_fast("reset the counter").genre != :decide
    end

    test "EXPRESS: message containing 'thanks' maps to :express" do
      assert Classifier.classify_fast("thanks for the help today").genre == :express
    end

    test "EXPRESS: message containing 'love' maps to :express" do
      assert Classifier.classify_fast("love the new approach").genre == :express
    end

    test "EXPRESS: message containing 'great' maps to :express" do
      assert Classifier.classify_fast("great job on the refactor").genre == :express
    end

    test "EXPRESS: message containing 'terrible' maps to :express" do
      assert Classifier.classify_fast("terrible performance today").genre == :express
    end

    test "EXPRESS: 'great' maps to :express even with words containing 'do' as substring" do
      # "done" contains "do" as substring but word-boundary matching prevents
      # false :direct match, so :express fires correctly for "great"
      assert Classifier.classify_fast("great work done").genre == :express
    end

    test "INFORM: unmatched message defaults to :inform" do
      assert Classifier.classify_fast("the deploy went out at 3pm").genre == :inform
    end

    test "INFORM: plain declarative statement without any genre keyword maps to :inform" do
      assert Classifier.classify_fast("the server started on port 8080").genre == :inform
    end

    test "INFORM: message with 'i' as substring does not falsely match :commit" do
      # "deployment" contains "i" and "me" as substrings but should not
      # trigger :commit since they are not whole words or phrases
      assert Classifier.classify_fast("deployment completed successfully").genre == :inform
    end

    test "INFORM: 'performance' does not falsely match :commit via 'me' substring" do
      assert Classifier.classify_fast("performance looks good").genre == :inform
    end

    test "DIRECT: 'run' keyword triggers :direct before :inform" do
      # This documents that 'run' belongs to :direct, not :execute mode only.
      assert Classifier.classify_fast("run the deployment script").genre == :direct
    end

    test "genre matching is case-insensitive" do
      assert Classifier.classify_fast("PLEASE do the thing").genre == :direct
      assert Classifier.classify_fast("I WILL handle it").genre == :commit
      # "APPROVE changes now" — uppercase is lowercased before matching
      assert Classifier.classify_fast("APPROVE changes now").genre == :decide
      # "love" with no commit keywords -> :express
      assert Classifier.classify_fast("love the result").genre == :express
    end
  end

  # ---------------------------------------------------------------------------
  # Type classification
  # ---------------------------------------------------------------------------

  describe "type classification" do
    test "returns 'question' when message contains a question mark" do
      assert Classifier.classify_fast("is the service healthy?").type == "question"
    end

    test "returns 'question' for 'what' keyword" do
      assert Classifier.classify_fast("what is the current memory usage").type == "question"
    end

    test "returns 'question' for 'how' keyword" do
      assert Classifier.classify_fast("how do I configure the database").type == "question"
    end

    test "returns 'question' for 'why' keyword" do
      assert Classifier.classify_fast("why is the test failing").type == "question"
    end

    test "returns 'question' for 'when' keyword" do
      assert Classifier.classify_fast("when was the last backup").type == "question"
    end

    test "returns 'question' for 'where' keyword" do
      assert Classifier.classify_fast("where are the log files stored").type == "question"
    end

    test "returns 'issue' for 'error' keyword" do
      assert Classifier.classify_fast("there is an error in production").type == "issue"
    end

    test "returns 'issue' for 'bug' keyword" do
      assert Classifier.classify_fast("found a bug in the auth flow").type == "issue"
    end

    test "returns 'issue' for 'broken' keyword" do
      assert Classifier.classify_fast("the pipeline is broken").type == "issue"
    end

    test "returns 'issue' for 'fail' keyword" do
      assert Classifier.classify_fast("the integration tests fail consistently").type == "issue"
    end

    test "returns 'issue' for 'crash' keyword" do
      assert Classifier.classify_fast("the worker process keeps crashing").type == "issue"
    end

    test "returns 'scheduling' for 'remind' keyword" do
      assert Classifier.classify_fast("remind me about the standup").type == "scheduling"
    end

    test "returns 'scheduling' for 'schedule' keyword" do
      assert Classifier.classify_fast("schedule the backup for midnight").type == "scheduling"
    end

    test "returns 'scheduling' for 'later' keyword" do
      assert Classifier.classify_fast("do this later today").type == "scheduling"
    end

    test "returns 'scheduling' for 'tomorrow' keyword" do
      assert Classifier.classify_fast("let's deploy tomorrow morning").type == "scheduling"
    end

    test "returns 'summary' for 'summarize' keyword" do
      assert Classifier.classify_fast("summarize the last sprint").type == "summary"
    end

    test "returns 'summary' for 'summary' keyword" do
      assert Classifier.classify_fast("I need a summary of this").type == "summary"
    end

    test "returns 'summary' for 'brief' keyword" do
      assert Classifier.classify_fast("brief me on the new features").type == "summary"
    end

    test "returns 'summary' for 'recap' keyword" do
      assert Classifier.classify_fast("recap of the meeting").type == "summary"
    end

    test "returns 'general' when no type keywords match" do
      assert Classifier.classify_fast("the deployment was successful").type == "general"
    end

    test "question mark takes priority over other type keywords" do
      # 'error' is present but '?' triggers question first in the cond chain
      assert Classifier.classify_fast("was there an error?").type == "question"
    end

    test "type matching is case-insensitive" do
      assert Classifier.classify_fast("ERROR in production").type == "issue"
      assert Classifier.classify_fast("REMIND me at noon").type == "scheduling"
      assert Classifier.classify_fast("SUMMARIZE the logs").type == "summary"
    end
  end

  # ---------------------------------------------------------------------------
  # Format classification
  # ---------------------------------------------------------------------------

  describe "format classification" do
    test ":cli channel produces :command format" do
      assert Classifier.classify_fast("do something", :cli).format == :command
    end

    test ":telegram channel produces :message format" do
      assert Classifier.classify_fast("do something", :telegram).format == :message
    end

    test ":discord channel produces :message format" do
      assert Classifier.classify_fast("do something", :discord).format == :message
    end

    test ":slack channel produces :message format" do
      assert Classifier.classify_fast("do something", :slack).format == :message
    end

    test ":whatsapp channel produces :message format" do
      assert Classifier.classify_fast("do something", :whatsapp).format == :message
    end

    test ":webhook channel produces :notification format" do
      assert Classifier.classify_fast("do something", :webhook).format == :notification
    end

    test ":filesystem channel produces :document format" do
      assert Classifier.classify_fast("do something", :filesystem).format == :document
    end

    test "unknown channel defaults to :message format" do
      assert Classifier.classify_fast("do something", :custom_channel).format == :message
    end

    test "default channel (no argument) uses :cli -> :command format" do
      assert Classifier.classify_fast("do something").format == :command
    end
  end

  # ---------------------------------------------------------------------------
  # Weight calculation — Shannon information content
  # ---------------------------------------------------------------------------

  describe "calculate_weight/1" do
    test "base weight is 0.5 for a zero-length message (no length bonus, no penalties)" do
      # Empty string: length=0, no question, no urgency, no noise keyword
      weight = Classifier.calculate_weight("")

      assert_in_delta weight, 0.5, 0.001
    end

    test "question bonus adds 0.15 to a message that has no noise or urgency keywords" do
      # "up?" — 3 chars, no noise keyword, has '?'
      # base 0.5 + length_bonus(3/500=0.006) + question_bonus 0.15 = 0.656
      weight = Classifier.calculate_weight("up?")

      assert_in_delta weight, 0.5 + 3 / 500.0 + 0.15, 0.001
    end

    test "question bonus adds exactly 0.15 compared to same message without question mark" do
      weight_no_q = Classifier.calculate_weight("the server started")
      weight_with_q = Classifier.calculate_weight("the server started?")

      # The only difference is the '?' character: +1 char length bonus + 0.15 question bonus
      # We check the question bonus portion dominates (within float tolerance)
      assert_in_delta weight_with_q - weight_no_q, 0.15 + 1 / 500.0, 0.001
    end

    test "urgency bonus adds 0.2 for 'urgent'" do
      weight = Classifier.calculate_weight("urgent fix needed")

      assert weight > 0.5
      assert weight >= 0.7
    end

    test "urgency bonus adds 0.2 for 'asap'" do
      weight = Classifier.calculate_weight("fix asap")

      assert weight >= 0.7
    end

    test "urgency bonus adds 0.2 for 'critical'" do
      # "critical" triggers urgency +0.2.  No noise keyword in "critical flaw found".
      weight = Classifier.calculate_weight("critical flaw found")

      assert weight >= 0.7
    end

    test "urgency bonus adds 0.2 for 'emergency'" do
      weight = Classifier.calculate_weight("emergency deploy required")

      assert weight >= 0.7
    end

    test "urgency bonus adds 0.2 for 'immediately'" do
      # "fix immediately" avoids the word "this" which embeds "hi" (noise penalty).
      weight = Classifier.calculate_weight("fix immediately")

      assert weight >= 0.7
    end

    test "noise penalty subtracts 0.3 for greeting 'hi'" do
      # "hi" = 2 chars, base 0.5 + 2/500=0.004 - 0.3 = 0.204
      weight = Classifier.calculate_weight("hi")

      assert_in_delta weight, 0.5 + 2 / 500.0 - 0.3, 0.001
    end

    test "noise penalty subtracts 0.3 for 'hello'" do
      # "hello" = 5 chars, base 0.5 + 5/500=0.01 - 0.3 = 0.21
      weight = Classifier.calculate_weight("hello")

      assert_in_delta weight, 0.5 + 5 / 500.0 - 0.3, 0.001
    end

    test "noise penalty subtracts 0.3 for 'hey'" do
      # "hey" = 3 chars, base 0.5 + 3/500=0.006 - 0.3 = 0.206
      weight = Classifier.calculate_weight("hey")

      assert_in_delta weight, 0.5 + 3 / 500.0 - 0.3, 0.001
    end

    test "noise penalty subtracts 0.3 for 'thanks'" do
      # "thanks" = 6 chars, base 0.5 + 6/500=0.012 - 0.3 = 0.212
      weight = Classifier.calculate_weight("thanks")

      assert_in_delta weight, 0.5 + 6 / 500.0 - 0.3, 0.001
    end

    test "noise penalty subtracts 0.3 for 'ok'" do
      # "ok" = 2 chars, base 0.5 + 2/500=0.004 - 0.3 = 0.204
      weight = Classifier.calculate_weight("ok")

      assert_in_delta weight, 0.5 + 2 / 500.0 - 0.3, 0.001
    end

    test "noise penalty subtracts 0.3 for 'lol'" do
      # "lol" = 3 chars, base 0.5 + 3/500=0.006 - 0.3 = 0.206
      weight = Classifier.calculate_weight("lol")

      assert_in_delta weight, 0.5 + 3 / 500.0 - 0.3, 0.001
    end

    test "length bonus is proportional: 500 chars yields max 0.2 bonus" do
      long_message = String.duplicate("a", 500)
      weight = Classifier.calculate_weight(long_message)

      # base 0.5 + length_bonus 0.2 = 0.7 (no other bonuses/penalties)
      assert_in_delta weight, 0.7, 0.01
    end

    test "length bonus caps at 0.2 even for very long messages" do
      very_long = String.duplicate("a", 1000)
      weight = Classifier.calculate_weight(very_long)

      # Should not exceed base + max_length_bonus
      assert weight <= 0.7
    end

    test "weight is capped at 1.0" do
      # urgent + question + very long = would exceed 1.0 without cap
      msg = String.duplicate("urgent fix needed? ", 30)
      weight = Classifier.calculate_weight(msg)

      assert weight <= 1.0
    end

    test "weight cannot go below 0.0" do
      # Multiple noise signals cannot drive weight negative
      weight = Classifier.calculate_weight("hi")

      assert weight >= 0.0
    end

    test "question bonus and urgency bonus stack" do
      # "status critical?" — 16 chars, no noise match, has '?', has 'critical'
      # base 0.5 + length(16/500=0.032) + question 0.15 + urgency 0.2 = 0.882
      weight = Classifier.calculate_weight("status critical?")

      assert weight >= 0.85
    end

    test "urgency and noise penalty together: net positive but reduced weight" do
      # "ok, urgent" contains 'ok' (noise -0.3) and 'urgent' (urgency +0.2)
      # base 0.5 + length(10/500=0.02) - 0.3 + 0.2 = ~0.42
      weight = Classifier.calculate_weight("ok, urgent")

      assert weight > 0.3
      assert weight < 0.6
    end

    test "message with 'this' does NOT trigger noise penalty (word-boundary matching)" do
      # "this" contains "hi" as a substring but word-boundary matching
      # prevents false noise penalty. Only standalone "hi" should penalize.
      without_this = Classifier.calculate_weight("fix asap")
      with_this = Classifier.calculate_weight("fix this asap")

      # The only difference should be the extra characters "this " (5 chars = 5/500 = 0.01)
      # No noise penalty should apply since "this" is not the word "hi"
      assert_in_delta with_this - without_this, 5 / 500.0, 0.001
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "empty string classifies without raising" do
      assert %Classifier{} = Classifier.classify_fast("")
    end

    test "empty string mode defaults to :assist" do
      assert Classifier.classify_fast("").mode == :assist
    end

    test "empty string weight is 0.5" do
      assert_in_delta Classifier.classify_fast("").weight, 0.5, 0.01
    end

    test "very long string (10_000 chars) classifies without raising" do
      long = String.duplicate("analyze this carefully ", 500)
      signal = Classifier.classify_fast(long)

      assert signal.mode == :analyze
      assert signal.weight <= 1.0
    end

    test "mixed signals: build + urgency produces :build mode" do
      signal = Classifier.classify_fast("create a dashboard urgently")

      assert signal.mode == :build
      assert signal.weight >= 0.7
    end

    test "mixed signals: multiple genre keywords — first match wins" do
      # 'please' appears before 'i will' in classify_genre cond, so :direct wins
      signal = Classifier.classify_fast("please, i will do this")

      assert signal.genre == :direct
    end

    test "unicode content in message does not raise" do
      signal = Classifier.classify_fast("analyze the \u{1F4CA} metrics")

      assert %Classifier{} = signal
      assert signal.mode == :analyze
    end

    test "message with only whitespace classifies without raising" do
      signal = Classifier.classify_fast("     ")

      assert %Classifier{} = signal
    end

    test "newlines and tabs in message are handled gracefully" do
      signal = Classifier.classify_fast("create\na\nnew\tfile")

      assert signal.mode == :build
    end
  end
end
