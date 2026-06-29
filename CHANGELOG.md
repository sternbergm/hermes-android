# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release notes for
versions prior to 1.0.7 are in the **What's new** sections of the [README](README.md).

## [Unreleased]

### Added
- **Background streaming.** A new app-lifetime `ChatStreamManager` owns the
  in-flight SSE stream (and its HTTP client) per session instead of the chat
  screen. Leaving the chat or switching apps no longer aborts the agent's
  reply — the stream keeps running and re-attaches when you return. If the OS
  kills the app mid-reply, the turn finishes server-side and the screen
  reconciles by refetching the transcript (and briefly polling for the pending
  reply) on return. The app bar shows **Responding…** while streaming and
  **Catching up…** while waiting for a server-side reply after a restart.

### Changed
- **Tool output stays collapsed.** Tool calls/results in the chat now render as
  compact, tappable chips (matching the inline progress chips shown while the
  agent responds) instead of expanding into their full input/output when a
  response finishes or a chat is re-opened. Tap a chip to reveal its details.

### Fixed
- **Conversations no longer halt while a slow model is thinking.** The chat
  stream used a default `http.Client`, whose underlying `HttpClient.idleTimeout`
  is 15 s. When a model took longer than that to produce its first token (common
  with large models or heavy tool contexts), no bytes flowed on the socket, Dart
  closed it as "idle", and the gateway aborted the turn
  (`interrupted_during_api_call`) — leaving the chat stuck on "Catching up…".
  The streaming client now uses a 10-minute idle timeout so quiet stretches
  don't drop the connection.
- **Chat opens at the bottom.** Entering a conversation (and finishing a
  response) now pins the view to the latest message like a normal chat app,
  rather than leaving it scrolled to the top.
- **Leaving a chat no longer cancels the agent.** Previously, navigating away
  from a streaming conversation disposed the screen and closed the HTTP client,
  cutting the agent off before it could answer.

## [1.0.7]

### Added
- Support for **password-protected dashboards**: the Memory, Cron Jobs, Skills,
  and Settings screens now authenticate against a basic-auth dashboard via the
  `/auth/password-login` flow and reuse the returned session cookie. Open
  (`--insecure`) dashboards continue to work via the existing token scrape.
- **Configurable dashboard port** per connection (`dashboardPortOverride`),
  defaulting to the previous behaviour (`9119` for HTTP, the external port for
  HTTPS) when unset.
- **Dashboard details in the Add Connection dialog** under a collapsible
  "Custom dashboard details" section, plus a **Dashboard Login** entry on each
  connection's overflow menu. Both validate the dashboard before saving.

### Changed
- `DashboardClient` accepts an optional `http.Client` for testability and
  de-duplicates concurrent login / token requests.

### Fixed
- Updating a connection's API key no longer clears its saved dashboard settings.
