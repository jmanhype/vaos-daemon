// src/lib/stores/voice.svelte.ts
// Voice input store — microphone recording + speech-to-text.
//
// Four transcription providers:
//   1. "local"   — Local Whisper via OSA backend (no API key, runs on device)
//   2. "groq"    — Groq Whisper API (fast, needs GROQ_API_KEY)
//   3. "openai"  — OpenAI Whisper API (needs OPENAI_API_KEY)
//   4. "browser" — Web Speech API (Chrome/Edge only, needs internet)
//
// Audio is recorded via MediaRecorder (works in all WebViews including Tauri).
// Keys are stored in localStorage.

export type VoiceProvider = "local" | "groq" | "openai" | "browser";

const VOICE_PROVIDER_KEY = "osa-voice-provider";
const GROQ_KEY_KEY = "osa-groq-api-key";
const OPENAI_KEY_KEY = "osa-openai-api-key";

class VoiceStore {
  // ── State ─────────────────────────────────────────────────────────────────
  isListening = $state(false);
  isTranscribing = $state(false);
  provider = $state<VoiceProvider>("local");
  error = $state<string | null>(null);
  interimText = $state("");
  hasBrowserSpeech = $state(false);

  // API keys (stored in localStorage)
  groqKey = $state("");
  openaiKey = $state("");

  // ── Private ───────────────────────────────────────────────────────────────
  #mediaRecorder: MediaRecorder | null = null;
  #audioChunks: Blob[] = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  #recognition: any = null;
  #onTranscript: ((text: string) => void) | null = null;

  constructor() {
    if (typeof window !== "undefined") {
      // Restore preferences
      const storedProvider = localStorage.getItem(VOICE_PROVIDER_KEY);
      if (
        storedProvider === "local" ||
        storedProvider === "groq" ||
        storedProvider === "openai" ||
        storedProvider === "browser"
      ) {
        this.provider = storedProvider;
      }

      this.groqKey = localStorage.getItem(GROQ_KEY_KEY) ?? "";
      this.openaiKey = localStorage.getItem(OPENAI_KEY_KEY) ?? "";

      this.hasBrowserSpeech =
        "SpeechRecognition" in window || "webkitSpeechRecognition" in window;
    }
  }

  // ── Configuration ─────────────────────────────────────────────────────────

  setProvider(provider: VoiceProvider): void {
    this.provider = provider;
    if (typeof window !== "undefined") {
      localStorage.setItem(VOICE_PROVIDER_KEY, provider);
    }
  }

  setGroqKey(key: string): void {
    this.groqKey = key;
    if (typeof window !== "undefined") {
      localStorage.setItem(GROQ_KEY_KEY, key);
    }
  }

  setOpenaiKey(key: string): void {
    this.openaiKey = key;
    if (typeof window !== "undefined") {
      localStorage.setItem(OPENAI_KEY_KEY, key);
    }
  }

  /** Whether the current provider is properly configured */
  get isConfigured(): boolean {
    switch (this.provider) {
      case "local":
        return this.hasBrowserSpeech; // Uses browser Speech API — no key needed
      case "groq":
        return this.groqKey.length > 0;
      case "openai":
        return this.openaiKey.length > 0;
      case "browser":
        return this.hasBrowserSpeech;
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  async startListening(onTranscript: (text: string) => void): Promise<void> {
    if (this.isListening) return;

    this.error = null;
    this.interimText = "";
    this.#onTranscript = onTranscript;

    try {
      if (this.provider === "local") {
        this.#startLocalRecognition();
      } else if (this.provider === "browser" && this.hasBrowserSpeech) {
        this.#startBrowserRecognition();
      } else {
        if (!this.isConfigured) {
          throw new Error(
            `No API key set for ${this.provider}. Add it in Settings > Voice.`,
          );
        }
        await this.#startCloudRecording();
      }
      this.isListening = true;
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to start voice input";
      this.isListening = false;
    }
  }

  stopListening(): void {
    if (!this.isListening) return;

    if (
      (this.provider === "local" || this.provider === "browser") &&
      this.#recognition
    ) {
      this.#recognition.stop();
      this.#recognition = null;
    } else if (
      this.#mediaRecorder &&
      this.#mediaRecorder.state !== "inactive"
    ) {
      this.#mediaRecorder.stop();
    }

    this.isListening = false;
  }

  // ── Local Speech Recognition (browser-native, no API key) ──────────────
  // Uses the Web Speech API for live interim results — works in Chrome,
  // Edge, and Tauri WebView2. No server round-trip needed.

  #startLocalRecognition(): void {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const w = window as any;
    const SR = w.SpeechRecognition ?? w.webkitSpeechRecognition;
    if (!SR) {
      throw new Error(
        "Speech recognition not available in this browser. Try Groq or OpenAI Whisper instead.",
      );
    }

    const recognition = new SR();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = "en-US";

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onresult = (e: any) => {
      let interim = "";
      let finalText = "";
      for (let i = 0; i < e.results.length; i++) {
        const result = e.results[i];
        if (result.isFinal) {
          finalText += result[0].transcript;
        } else {
          interim += result[0].transcript;
        }
      }
      this.interimText = interim;
      if (finalText) {
        this.#onTranscript?.(finalText);
        this.interimText = "";
      }
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onerror = (e: any) => {
      if (e.error === "no-speech") return; // Ignore silence
      if (e.error === "aborted") return; // User-initiated stop
      if (e.error === "service-not-allowed" || e.error === "not-allowed") {
        this.error =
          "Microphone access denied. Allow microphone in browser settings, or use Groq/OpenAI Whisper instead.";
      } else {
        this.error = `Speech error: ${e.error}`;
      }
      this.isListening = false;
    };

    recognition.onend = () => {
      // If still supposed to be listening, auto-restart (browser sometimes stops)
      if (this.isListening && this.provider === "local") {
        try {
          recognition.start();
        } catch {
          this.isListening = false;
          this.interimText = "";
        }
        return;
      }
      this.isListening = false;
      this.interimText = "";
    };

    recognition.start();
    this.#recognition = recognition;
  }

  async toggle(onTranscript: (text: string) => void): Promise<void> {
    if (this.isListening) {
      this.stopListening();
    } else {
      await this.startListening(onTranscript);
    }
  }

  // ── Browser Speech API ────────────────────────────────────────────────────

  #startBrowserRecognition(): void {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const w = window as any;
    const SR = w.SpeechRecognition ?? w.webkitSpeechRecognition;
    if (!SR)
      throw new Error("Speech recognition not supported in this browser");

    const recognition = new SR();
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.lang = "en-US";

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onresult = (e: any) => {
      let interim = "";
      let finalText = "";
      for (let i = 0; i < e.results.length; i++) {
        const result = e.results[i];
        if (result.isFinal) {
          finalText += result[0].transcript;
        } else {
          interim += result[0].transcript;
        }
      }
      this.interimText = interim;
      if (finalText) {
        this.#onTranscript?.(finalText);
      }
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onerror = (e: any) => {
      this.error = `Speech error: ${e.error}`;
      this.isListening = false;
    };

    recognition.onend = () => {
      this.isListening = false;
      this.interimText = "";
    };

    recognition.start();
    this.#recognition = recognition;
  }

  // ── Cloud Recording (Groq / OpenAI Whisper) ───────────────────────────────

  async #startCloudRecording(): Promise<void> {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        sampleRate: 16000,
        echoCancellation: true,
        noiseSuppression: true,
      },
    });

    this.#audioChunks = [];

    const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : "audio/webm";

    const recorder = new MediaRecorder(stream, { mimeType });

    recorder.ondataavailable = (e) => {
      if (e.data.size > 0) {
        this.#audioChunks.push(e.data);
      }
    };

    recorder.onstop = async () => {
      stream.getTracks().forEach((t) => t.stop());
      if (this.#audioChunks.length === 0) return;

      const audioBlob = new Blob(this.#audioChunks, { type: mimeType });
      this.isTranscribing = true;
      try {
        await this.#transcribeCloud(audioBlob);
      } finally {
        this.isTranscribing = false;
      }
    };

    recorder.start(250);
    this.#mediaRecorder = recorder;
  }

  async #transcribeCloud(audioBlob: Blob): Promise<void> {
    try {
      const formData = new FormData();
      formData.append("file", audioBlob, "recording.webm");
      formData.append("model", "whisper-large-v3-turbo");
      formData.append("response_format", "json");

      let url: string;
      let apiKey: string;

      if (this.provider === "groq") {
        url = "https://api.groq.com/openai/v1/audio/transcriptions";
        apiKey = this.groqKey;
      } else {
        url = "https://api.openai.com/v1/audio/transcriptions";
        apiKey = this.openaiKey;
        // OpenAI uses whisper-1
        formData.set("model", "whisper-1");
      }

      const res = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        body: formData,
      });

      if (!res.ok) {
        const errBody = await res.text().catch(() => `HTTP ${res.status}`);
        this.error = `Transcription failed (${res.status}): ${errBody}`;
        return;
      }

      const data = (await res.json()) as { text?: string };
      const transcript = data.text ?? "";

      if (transcript.trim()) {
        this.#onTranscript?.(transcript.trim());
      }
    } catch (err) {
      this.error = err instanceof Error ? err.message : "Transcription failed";
    } finally {
      this.interimText = "";
    }
  }
}

export const voiceStore = new VoiceStore();
