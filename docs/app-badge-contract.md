# App badge bridge contract

The notification inbox sends the following one-way message after its list has
successfully fetched after the current page mount:

```json
{"type":"CLEAR_BADGE","data":null}
```

`FlutterWebViewBridgeJavaScriptChannel` awaits `onClearBadge` once and returns
without posting a JavaScript response. The callback is optional so a new web
deployment remains compatible with an older or partially integrated app.

The app callback clears only the launcher badge with
`AppBadgePlus.updateBadge(0)`. It must not call notification cancellation APIs;
active notification-tray entries remain intact. Android launcher support varies,
so an unsupported launcher must be treated as a no-crash/no-user-error outcome.

Clearing the device badge does not itself reset a server-side unread counter.
Before production release, verify that the first push after a clear carries a
badge value of `1`.
