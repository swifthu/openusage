# Menu bar

Star the metrics you watch most and they show in the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a short menu with **Settings** and **Quit**.
Left-click opens the panel.

## Starring

Star a metric from its right-click menu on the dashboard, or with the star on its row on an account's
page in Accounts.

- Each provider ships with default stars (for example Claude Session and Weekly, ChatGPT Session and
  Weekly, Cursor Models and Other Models, OpenRouter Balance), so the strip shows numbers as soon as
  an account refreshes. Change them any time.
- At most **two stars per provider**.
- When a star is not allowed, the star stays clickable. Clicking it shows the reason in a short pill.
- Hiding a metric takes its star off the menu bar. Starring a hidden metric shows it again.

## What the strip shows

Each starred metric shows its provider's mark and the value. Two starred metrics from the same
account stack as a labelled pair. A metric that counts down to a reset — MiniMax's **5h Reset** — is
drawn as a bar draining towards that reset instead of as text, but only while a second metric of the
same account is starred beside it; starred on its own it keeps the countdown.

The bar is the same bar throughout the window, and it changes color as the window winds down. While
the window has time left it is white and drains over the whole window — five hours for **5h Reset**.
Over the window's last hour it restarts from full and walks down over that hour instead, and takes
the app's warning colour. When that last hour is down to its final fifth, the bar takes the critical
colour. The strip only renders real data: a starred metric with nothing fetched yet is skipped, and
an account whose stars all lack data disappears from the strip. When
nothing has data, the strip shows the app icon. With [Hide From Screen Share](privacy.md#screen-sharing)
on, it also shows the app icon while your screen is shared or recorded. The strip, or the app icon in
its place, dims while an account's values are out of date because its refreshes fail or a provider
asked OpenUsage to wait (see [Refreshing](refreshing.md)), and VoiceOver adds "waiting for a provider".

When the strip shows more than one account of a provider, each mark carries the account name's
initials: the first letter of its first word and of its last, so "Personal" reads P and "Attention
Machine 1" reads A1. Two accounts named alike share a tag; rename one to tell them apart.

Stars follow your dashboard order.

## Size

The strip is drawn at 100% of its default size. **Menu Bar Size** in Settings scales it from 70% to
130%: the provider mark, the values, the spacing between them and the countdown bar all grow or
shrink together. The menu bar has a fixed height, so past the top of the range the strip is cut off
by the system. The setting applies right away, and it also scales the app icon shown when nothing is
starred.
