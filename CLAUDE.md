# Stern — agent notes

## Time zones in admin views

`AuthenticatedController` wraps every request in `Time.use_zone(passport_time_zone)`,
resolved from the IDP user's `time_zone` claim (UTC fallback). Inside admin
controllers and views:

- Use `Time.current` / `Time.zone.now` / `Time.zone.parse(str)` — never `DateTime.current`
  or `DateTime.parse`, which ignore `Time.zone`.
- For values rendered into a `<input type="datetime-local">`, format the
  zoned time as `%Y-%m-%dT%H:%M`. The user types wall-clock; `Time.zone.parse`
  reattaches the offset on submit.
- For displaying stored UTC timestamps (e.g. `Stern::Entry#timestamp`), call
  `.in_time_zone.strftime(...)`.
- The date range picker (`_date_range_picker.html.erb`) reads `Time.zone.tzinfo.name`
  and uses Luxon (vendored at `app/assets/builds/luxon.min.js`) so JS presets
  respect the passport zone, not the browser zone.

When adding a new admin controller, inheriting from `AuthenticatedController`
is enough — the `around_action` does the work.
