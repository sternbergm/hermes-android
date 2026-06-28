# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release notes for
versions prior to 1.0.7 are in the **What's new** sections of the [README](README.md).

## [Unreleased]

### Changed
- **Tool output stays collapsed.** Tool calls/results in the chat now render as
  compact, tappable chips (matching the inline progress chips shown while the
  agent responds) instead of expanding into their full input/output when a
  response finishes or a chat is re-opened. Tap a chip to reveal its details.

### Fixed
- **Chat opens at the bottom.** Entering a conversation (and finishing a
  response) now pins the view to the latest message like a normal chat app,
  rather than leaving it scrolled to the top.

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
