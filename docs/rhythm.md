# Usage Rhythm

The **Rhythm** tab of the dashboard records how fast each account's limits fill up, and shows when
your busy hours are.

## What is recorded

Every refresh, the app notes how much of each limit's window has been used and when. From those
notes it builds a five-minute history of the last 90 days, kept in
`~/Library/Application Support/OpenUsage/rhythm/<bundle id>/`, one file per local day. The app's
bundle identifier is in the path, so a development build and the installed app never write over
each other's history.

What a file holds is the share of the window that was used, the provider it came from, the name of
the metric and a local account id. It never holds a token count, a price, an account name or an
email address. Nothing leaves this Mac: the history is never uploaded, and the app never reads the
logs of other tools.

Only windows of a day or less are recorded. A weekly limit sampled every few minutes is a slow
drift, and its hourly rate says nothing about when you are actually working.

A metric whose unit is money is not recorded. A dollar budget is the rate at which money is
spent, and this app does not chart spending. What the chart carries is the share of each recorded
window — a percentage or a count — and nothing else.

## The two views

**This Day** shows one day. The arrows step a day at a time, and a long press on the date opens a
calendar. **Average** shows the last 7, 30 or 90 days averaged, so the shape of a usual week shows
through the noise of one day.

## Zooming in

The chart always has 24 bars. The zoom control changes how much of the day they cover: a day, half
a day, six hours or two hours. Above the chart, the strip of the whole day marks the window the
chart is showing; drag that mark to move the window through the day.

## Reading the chart

A bar's height is how much of the window that slice burned, as a share of the window. The peak is
drawn in the app's blue and the rest in a lighter shade of it. A slice that was read but not used
shows a thin baseline. A slice nothing was read from stays empty: "we do not know" is not "nothing
was used".

The chart adds up the share of every recorded window, including windows of different lengths: two
accounts whose windows each burned 5% make a bar of 10 points. The unit above the chart says how
much time each bar covers, so it follows the zoom level — "Percentage Points / Hour" for a whole
day, "Percentage Points / 5 Minutes" for the narrowest one.

Turn the recording off in **Settings → Display → Usage → Record Usage Rhythm**, and remove what was
already recorded with **Delete Rhythm History**, which asks before it removes anything. The two are
separate: turning the recording off keeps the history, and deleting the history leaves the recording
on. While the recording is on, the current day's file fills up again.

The delete button is greyed out when the settings screen finds no history to remove. It is checked
when the screen is opened, so a history that is recorded afterwards is only removed once the screen
is opened again.
