# iOS widgets

## Home Screen widget

Add **Reattach → Pending Requests** from the Home Screen widget gallery. Small and medium sizes show pending requests across all configured servers and last successful update. Tap to open the permission inbox.

Open Reattach and add your servers first. The app shares its latest snapshot with the widget. The widget also requests a refresh approximately every 15 minutes; iOS controls the actual schedule, so this is not a real-time alert. A failed refresh preserves the last successful data and marks it as outdated. Device and optional Cloudflare service credentials are shared through the App Group keychain. Cloudflare browser sign-in cookies are not shared with the widget.

The **automatically open pending requests** setting in Servers → App Settings applies to all servers on this device and opens the inbox while Reattach is in the foreground. It does not launch the iOS app from the background.

On iOS 26 and later, the widget registers a dedicated WidgetKit push token with each configured server. The daemon watches the permission list approximately every 3 seconds while subscriptions exist and sends a silent `widgets` push when requests appear, change, or clear. It does not create a notification banner or sound. WidgetKit then obtains a fresh timeline from the server. iOS still budgets delivery; pushes do not guarantee instant updates, and the 15-minute timeline request remains as a fallback. Earlier iOS versions retain the periodic refresh behavior.

Widget subscriptions use `/widget-devices`, require a paired device credential even when the daemon has no paired devices, and are stored separately from normal notification tokens. Tokens rotate per authenticated device and APNs environment. Removing or changing a server, or removing the widget, requests unsubscription; unavailable servers expire registrations after three days without renewal. Revoked devices are excluded from delivery. Development versus production APNs is determined from the extension's signing profile, including Release builds installed directly from Xcode.

The global inbox and widget are in iOS build 48. Previously uploaded build 44 does not include the widget.

Reference: https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications

The permission inbox groups each request by server identity and pane target, so identical targets on different servers stay distinct. Each card names its server; replies use that server's saved credentials without switching the selected terminal server. Opening the pane explicitly switches to its server. Connection failures retain the last known requests and show the servers that could not be refreshed; they do not count as confirmed zero requests.

The toolbar's server-rack icon opens the current server's settings. Global app preferences are accessed from the gear icon in the server list.

Normal notification registration also follows the app's signed provisioning profile rather than the Debug/Release build configuration. This matters for Release builds installed directly from Xcode, which still use development APNs. The device registers normal notification tokens with all configured servers independently from widget tokens.

## Unread activity and notification preferences

Blue indicators and the widget count represent panes with output that has not been
confirmed on this device. Permission requests remain orange. The daemon persists
read receipts per paired device; notification delivery does not determine read state.
The app acknowledges the displayed revision so an older acknowledgement cannot clear
newer output. Each configured server must support `GET /activity` and
`POST /activity/read` (authenticated even in open mode).

App Settings offers all notifications, permission requests only, or off. This preference
applies to all configured servers for this device and to both APNs environments.
Unread tracking and widget updates remain independent of visible notifications.

Widget reloads are requested when unread counts increase or decrease, including after
reading or deleting a pane. WidgetKit controls actual delivery and rendering time.
If unread data cannot be fetched, cached counts are preserved and marked unavailable.
The permission inbox can also close automatically after all requests resolve; connection
failures do not count as a confirmed empty inbox.
