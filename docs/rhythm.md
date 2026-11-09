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

What is kept about a window is its rate: how much of it was burned between two readings. The share
that was left at every reading is kept for the 5-hour windows only, and only when **Track 5-Hour
Windows** is on — that is what the chart's dashed line draws. It is the share of the provider's own
window, never a token count, a price or an estimate of anything.

A metric whose unit is money is not recorded. A dollar budget is the rate at which money is
spent, and this app does not chart spending. What the chart carries is the share of each recorded
window — a percentage or a count — and nothing else.

The history is kept in the app's own format, and the app never writes over a file it cannot read.
If a day's file cannot be read — after a change of time zone, for instance, its five-minute
buckets no longer fit the day — that day records nothing, the file is left exactly as it is, and
the chart says the day could not be read. The app asks the file again before it writes, so a file
that is replaced while the app is running — a restored backup, for instance — is left alone too.
The one exception is a file that is not valid JSON at all: there is nothing in it to keep, so it
is replaced.

A burn that crosses the midnight belongs to both days it touches: the part before the midnight to
the day that ended, the rest to the day that began. Nothing of it is lost, and neither day's
figure counts it twice.

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

A window that holds no reading of its own is still a chart: the day it belongs to was read
somewhere else, and the chart stays so the reader can move back to the part that has them. Only a
day that was never read says that nothing was recorded on it.

## The remaining share of a 5-hour window

Above the chart, next to the unit, a picker chooses the 5-hour window the dashed line follows.
Every account has its own, and the choice is kept, so the chart shows the same window the next
time. A window that is not in the history any more is not on offer, and the first one takes its
place.

The line is the share the chosen window still had left at every reading. A window that resets
every five hours therefore shows as a line that climbs back up: the share before a reset and the
share after it are two runs of the same window.

The bars and the line are counted in different things — a bar is a rate, the line is a share — so
the chart has an axis for each. The left axis is the bars', from zero to the tallest bar; the
right axis is the line's, from 0% to 100%.

Keeping the share is a setting of its own: **Settings → Display → Usage → Track 5-Hour Windows**.
With it off, the app keeps the rate of every window as before and no share is kept, so the line
is gone.

Turn the recording off in **Settings → Display → Usage → Record Usage Rhythm**, and remove what was
already recorded with **Delete Rhythm History**, which asks before it removes anything. The two are
separate: turning the recording off keeps the history, and deleting the history leaves the recording
on. While the recording is on, the current day's file fills up again.

The delete button is greyed out when the settings screen finds no history to remove. It is checked
when the screen is opened, so a history that is recorded afterwards is only removed once the screen
is opened again.
