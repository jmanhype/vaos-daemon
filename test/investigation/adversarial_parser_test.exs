defmodule Daemon.Investigation.AdversarialParserTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.AdversarialParser

  test "parses strict adversarial output format" do
    text = """
    1. [SOURCED] (strength: 9) Magnesium modestly improves sleep onset latency in older adults [Paper 2]
    2. [REASONING] (strength: 4) The effect may depend on baseline deficiency
    """

    assert [
             %{source_type: :sourced, strength: 9, paper_ref: 2},
             %{source_type: :reasoning, strength: 4, paper_ref: nil}
           ] = AdversarialParser.parse(text)
  end

  test "parses nearby markdown and score variants" do
    text = """
    1) **[SOURCED]** Score: 8 - Meta-analysis reports better sleep efficiency [Paper 4]
    - [REASONING] Strength: 3 - The result may be confounded by placebo response
    """

    assert [
             %{source_type: :sourced, strength: 8, paper_ref: 4},
             %{source_type: :reasoning, strength: 3}
           ] = AdversarialParser.parse(text)
  end

  test "falls back to sourced paragraphs when papers are cited without strict formatting" do
    text = """
    Magnesium supplementation improved subjective sleep quality and reduced latency in a small trial [Paper 1].

    Another paragraph without a citation should be ignored.
    """

    assert [
             %{
               source_type: :sourced,
               strength: 5,
               paper_ref: 1,
               summary: summary
             }
           ] = AdversarialParser.parse(text)

    assert String.contains?(
             summary,
             "Magnesium supplementation improved subjective sleep quality"
           )
  end

  test "accepts bare Paper N references as citations" do
    text = """
    1. [SOURCED] (strength: 7) Paper 2 reports better sleep efficiency after supplementation in adults.
    """

    assert [
             %{source_type: :sourced, strength: 7, paper_ref: 2}
           ] = AdversarialParser.parse(text)
  end

  test "demotes sourced items without any paper reference to reasoning" do
    text = """
    1. [SOURCED] (strength: 8) This paragraph makes a claim but never cites any paper.
    """

    assert [
             %{source_type: :reasoning, strength: 8, paper_ref: nil}
           ] = AdversarialParser.parse(text)
  end

  test "parses strength values written as n/10" do
    text = """
    1. [SOURCED] (strength: 2/10) [Paper 4] Ancient thinkers entertained flat-earth cosmology as part of a broader system.
    """

    assert [
             %{source_type: :sourced, strength: 2, paper_ref: 4, summary: summary}
           ] = AdversarialParser.parse(text)

    refute summary =~ "(strength:"
  end
end
