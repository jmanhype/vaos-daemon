"""
DSPy Signatures for the investigation pipeline.

Three signatures mirror the Elixir pipeline:
  - ForAdvocate: make the strongest case FOR a claim
  - AgainstAdvocate: make the strongest case AGAINST a claim
  - VerifyCitation: verify whether a paper abstract supports a claim
"""

import dspy


class ForAdvocate(dspy.Signature):
    """Make the strongest case FOR a claim based on research papers.
    Only cite what paper abstracts explicitly state. Mark each argument
    as [SOURCED] with [Paper N] or [REASONING] if from your analysis."""

    claim = dspy.InputField(desc="The claim to argue FOR")
    papers_context = dspy.InputField(desc="Formatted papers with abstracts")
    prior_evidence = dspy.InputField(
        desc="Prior evidence from related investigations", default=""
    )
    evidence = dspy.OutputField(
        desc="3-5 numbered arguments: [SOURCED/REASONING] (strength: N) text [Paper N]"
    )


class AgainstAdvocate(dspy.Signature):
    """Make the strongest case AGAINST a claim based on research papers.
    Only cite what paper abstracts explicitly state. Mark each argument
    as [SOURCED] with [Paper N] or [REASONING] if from your analysis."""

    claim = dspy.InputField(desc="The claim to argue AGAINST")
    papers_context = dspy.InputField(desc="Formatted papers with abstracts")
    prior_evidence = dspy.InputField(
        desc="Prior evidence from related investigations", default=""
    )
    evidence = dspy.OutputField(
        desc="3-5 numbered counterarguments: [SOURCED/REASONING] (strength: N) text [Paper N]"
    )


class VerifyCitation(dspy.Signature):
    """Verify whether a paper's abstract supports a specific claim.
    Respond with verification status and paper type classification."""

    paper_title = dspy.InputField(desc="Title of the paper being verified")
    paper_abstract = dspy.InputField(desc="Abstract text of the paper (up to 2000 chars)")
    claim = dspy.InputField(desc="The specific claim to verify against the abstract")
    verdict = dspy.OutputField(
        desc="Two words: VERIFIED/PARTIAL/UNVERIFIED + REVIEW/TRIAL/STUDY/OTHER"
    )
