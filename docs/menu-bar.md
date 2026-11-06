# Menu bar

The strip shows the limits closest to running out. You only choose how many.

- Left-click the icon to open the panel. Right-click (or control-click) it for **Settings** and
  **Quit OpenUsage**.
- The strip shows the top limits of the dashboard's [Running Out](dashboard.md#priority) list, up to
  **Settings → Display → Priority → Show In Menu Bar** (3 by default).
- Each limit shows the provider's mark, a short name, and its value. An account can appear more than once.
- Limits past that number show as a count, like `+7`. Used-up limits and balances never show or count.
- With nothing running out, or with **App Icon Only**, the strip shows the app icon.
- With [Hide From Screen Share](privacy.md#screen-sharing) on, it shows the app icon while your screen
  is shared or recorded.
- When an [update](updates.md) is available, the app icon shows at the end of the strip until the
  update banner goes away.
- When a provider has more than one account, its mark carries the account name's initials: "Personal"
  reads P and "Attention Machine 1" reads A1. Rename one of two accounts with the same initials to tell
  them apart.

## The countdown bar

A limit whose window resets within a day carries a small bar beside its value, draining towards that
reset. The filled part is the time still to run.

The bar is the same bar throughout the window, and it changes color as the window winds down. While the
window has time left it is white and drains over the whole window — five hours for a 5-hour session.
Over the window's last hour it restarts from full and walks down over that hour instead of looking
stalled at the tail of a long window, and takes the app's warning colour. When that last hour is down
to its final fifth, the bar takes the critical colour. A window longer than a day has no bar: it would
sit near full for days.

## Size

The strip is drawn at 100% of its default size. **Menu Bar Size** in Settings → Display scales it from
70% to 130%: the provider mark, the values, the spacing between them and the countdown bar all grow or
shrink together. The menu bar has a fixed height, so past the top of the range the strip is cut off by
the system. The setting applies right away, and it also scales the app icon shown when the strip has
nothing to show.
