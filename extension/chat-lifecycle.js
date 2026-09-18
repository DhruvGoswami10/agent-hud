// Shared conversation state machine. DOM absence alone never proves success.
(function (root) {
  class HUDChatLifecycle {
    constructor({ provider, canonical, send, aliases = {}, remember = () => {} }) {
      Object.assign(this, { provider, canonical, send, aliases, remember });
      this.active = false;
      this.path = "";
      this.id = "";
      this.name = "";
      this.lastBeat = 0;
      this.missingAt = null;
      this.interrupted = false;
    }
    emit(event, message, outcome = "") {
      this.send({ event, host: "web", app: this.provider, project: this.provider === "chatgpt" ? "ChatGPT" : "Claude",
        session_id: this.id, session_name: this.name, message, outcome, hook: "browser",
        focus: { url: this.url || "" } });
    }
    stop(outcome, message) {
      if (this.active) this.emit("done", message, outcome);
      this.active = false;
      this.missingAt = null;
      this.interrupted = false;
    }
    tick({ path, title, generating, url, error = false, completed = false, now = Date.now() }) {
      const canonical = this.canonical(path);
      const adoption = this.active && !this.canonical(this.path) && !!canonical;
      if (this.active && path !== this.path && !adoption) {
        this.stop("unknown", "Conversation left · completion unconfirmed");
      }
      if (generating && !this.active) {
        this.id = canonical ? (this.aliases[canonical] || this.provider + "-" + canonical)
          : this.provider + "-new-" + Math.random().toString(36).slice(2);
        this.active = true;
        this.lastBeat = 0;
        this.path = path;
        this.missingAt = null;
      }
      if (!this.active) return;
      if (adoption) {
        this.aliases[canonical] = this.id;
        const keys = Object.keys(this.aliases);
        for (const key of keys.slice(0, Math.max(0, keys.length - 100))) delete this.aliases[key];
        this.remember(this.aliases);
      }
      this.path = path;
      this.name = title;
      this.url = canonical ? url : "";
      if (error) { this.stop("error", "Response reported an error"); return; }
      if (generating) {
        this.missingAt = null;
        if (!this.lastBeat || now - this.lastBeat >= 30000) {
          this.emit("running", "generating…");
          this.lastBeat = now;
        }
      } else {
        this.missingAt ??= now;
        if (now - this.missingAt >= 2000) {
          const outcome = this.interrupted ? "interrupted" : completed ? "finished" : "unknown";
          this.stop(outcome, { interrupted: "Response stopped", finished: "Response finished",
            unknown: "Response stopped · completion unconfirmed" }[outcome]);
        }
      }
    }
  }
  root.HUDChatLifecycle = HUDChatLifecycle;
})(globalThis);
