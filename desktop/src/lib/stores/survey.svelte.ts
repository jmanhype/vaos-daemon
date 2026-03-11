// src/lib/stores/survey.svelte.ts
// Survey store — manages a queue of pending surveys, surfaces one at a time,
// and posts completed answers to the backend.

const BASE_URL = "http://127.0.0.1:9089";
const API_PREFIX = "/api/v1";

// ── Domain Types ──────────────────────────────────────────────────────────────

export interface Option {
  id: string;
  label: string;
  description?: string;
}

export interface Question {
  text: string;
  subtitle?: string;
  options: Option[];
  /** Whether to show a freeform "Type your own" card at the bottom. */
  allowCustom: boolean;
  /** Whether advancing without selecting anything is permitted. */
  skippable: boolean;
}

export interface Survey {
  id: string;
  questions: Question[];
}

export interface Answer {
  questionIndex: number;
  selectedOptionId: string | null;
  customText: string | null;
}

// ── Internal queue entry ───────────────────────────────────────────────────────

interface SurveyEntry {
  survey: Survey;
  /** Session ID to POST answers against, if any. */
  sessionId?: string;
  resolve: (answers: Answer[]) => void;
  reject: (reason?: unknown) => void;
}

// ── Store Class ───────────────────────────────────────────────────────────────

class SurveyStore {
  /** The survey currently being shown to the user, or null. */
  activeSurvey = $state<Survey | null>(null);

  /** True while a POST to the backend is in flight. */
  isSubmitting = $state(false);

  /** Last submission error, cleared on next show(). */
  submitError = $state<string | null>(null);

  #queue: SurveyEntry[] = [];
  #active: SurveyEntry | null = null;

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Queue a survey for display.
   * Returns a promise that resolves with the user's answers when they
   * complete the survey, or rejects if they dismiss it.
   */
  showSurvey(survey: Survey, sessionId?: string): Promise<Answer[]> {
    return new Promise<Answer[]>((resolve, reject) => {
      this.#queue.push({ survey, sessionId, resolve, reject });
      this.#maybeShowNext();
    });
  }

  /** Called by SurveyDialog when the user completes all questions. */
  async handleComplete(answers: Answer[]): Promise<void> {
    if (!this.#active) return;

    const entry = this.#active;
    this.activeSurvey = null;
    this.#active = null;

    if (entry.sessionId) {
      await this.#postAnswers(entry.survey.id, entry.sessionId, answers);
    }

    entry.resolve(answers);
    this.#maybeShowNext();
  }

  /** Called by SurveyDialog when the user clicks Dismiss. */
  handleDismiss(): void {
    if (!this.#active) return;
    const entry = this.#active;
    this.activeSurvey = null;
    this.#active = null;
    entry.reject(new Error("dismissed"));
    this.#maybeShowNext();
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  #maybeShowNext(): void {
    if (this.#active !== null) return;
    if (this.#queue.length === 0) return;

    const next = this.#queue.shift()!;
    this.#active = next;
    this.submitError = null;
    this.activeSurvey = next.survey;
  }

  async #postAnswers(
    surveyId: string,
    sessionId: string,
    answers: Answer[],
  ): Promise<void> {
    this.isSubmitting = true;
    this.submitError = null;

    try {
      const url = `${BASE_URL}${API_PREFIX}/sessions/${sessionId}/survey/answer`;
      const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ survey_id: surveyId, answers }),
      });

      if (!response.ok) {
        const text = await response.text().catch(() => "");
        this.submitError = `Failed to submit survey (${response.status}): ${text}`;
      }
    } catch (e) {
      this.submitError = (e as Error).message;
    } finally {
      this.isSubmitting = false;
    }
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const surveyStore = new SurveyStore();
