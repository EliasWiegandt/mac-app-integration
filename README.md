# Local Mac App Integrations MCP

A small MCP server for Apple Calendar and Reminders, read-only access to one iCloud Mail account configured in Apple Mail, and editable walking and cycling tours using MapKit. It uses Swift, EventKit, MapKit, Apple Mail automation, and the MCP Swift SDK.

## Start it

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode Command Line Tools).

From this folder, run:

```sh
cp .env.example .env
# Edit .env once to set your iCloud Mail address.
make run
```

The `.env` setup is one time only. The file is Git-ignored and contains the address of the Apple Mail account the Mail tools may access. It does not need a password. Leave the Terminal window open while using the tools. Press Ctrl-C to stop the server. `make run` builds an app bundle and starts the MCP endpoint at `http://127.0.0.1:8765/mcp`. It listens only on this Mac's loopback interface. **No tunnel client is needed for the local ChatGPT desktop app.**

The first Calendar or Reminders tool call may trigger a macOS permission prompt. Grant access to both when prompted. If access was previously denied, enable **Local Calendar MCP** in **System Settings → Privacy & Security → Calendars** or **Reminders**. The generated app bundle carries the permission descriptions; launch the server through `make run` rather than running the bare Swift binary.

Mail search requires the address in `.env` to be configured and enabled in Apple Mail. The first Mail tool call may ask you to allow macOS Automation access to Mail. Check **System Settings → Privacy & Security → Automation** if you denied it. No iCloud password is stored in this project. Mail tools are scoped to this account; other Mail accounts are not searched. Search covers message subjects and senders across its mailboxes, then `read_icloud_mail` retrieves one selected message's text body. Full-text body search is not included.

## Connect ChatGPT on this Mac

In the ChatGPT desktop app, add an MCP server in **Settings → MCP servers** using **Streamable HTTP** and the URL `http://127.0.0.1:8765/mcp`. Save and restart ChatGPT if prompted. This is a one-time setup. With `make run` running, try “List my reminder lists” or “List my calendars.”

You can name the local connection `local-mac-app-integrations`. Each Mac needs its own connection setup.

## Tools

| Reminders | Calendar |
| --- | --- |
| `list_reminder_lists` | `list_calendars` |
| `search_reminders` | `search_events` |
| `create_reminder` | `create_event` |
| `update_reminder` | `update_event` |
| `delete_reminder` | `delete_event` |

Calendar invitations: `invite_event_attendee` takes an event ID and a guest email address. It uses Apple Calendar automation because EventKit cannot add guests. The first use may ask for Automation permission for Calendar. The tool supports timed, nonrecurring events on writable calendars. It checks the calendar, title, and exact start time and refuses ambiguous matches. Existing guests are reported without adding a duplicate. Adding a guest may send an invitation immediately; the tool can confirm the attendee appears in Calendar but cannot verify delivery to the guest.

Mail: `search_icloud_mail`, `read_icloud_mail`, `list_icloud_mail_attachments`, and `download_icloud_mail_attachment`. List attachments for a message ID, then download one by its attachment ID. Downloads are saved to a unique folder under `~/Library/Application Support/LocalMacAppIntegrations/Attachments/`; the tool returns the absolute path. These copies persist until you remove them. Downloading does not send or delete mail. Apple Mail may leave `mime_type` empty even when it provides the file name and size.

### Walking and cycling tours

The tour tools let you plan a neighborhood walk or bike ride in conversation, revise it on the move, and open a fresh handoff on your iPhone:

1. Use `search_map_places` to resolve sights and addresses, preferably with nearby coordinates for the town or neighborhood; check that the returned place names match what you intended. Then use `create_tour` with their coordinates in order. Set `mode` to `walking` or `cycling` (walking is the default). The tour is saved privately on this Mac. Existing tours can switch modes with `set_tour_mode`.
2. Use `preview_tour` to check travel times and distances between stops. `get_tour` or `list_tours` returns the latest Apple Maps link. Open the link on iPhone and review it before starting navigation.
3. For a detour, tell the assistant your current location. `suggest_tour_detours` finds places reachable within a specified travel time, such as coffee within 30 minutes by bike, and ranks them by how much time they add before your next stop. After you choose one, `insert_tour_stop` adds it before a remaining stop. `remove_tour_stop` removes a future stop, and `set_tour_progress` marks the next stop and current position. `preview_tour` and the Apple Maps link then reflect the revised plan. For more sights like one you enjoyed, search by its descriptive category and add the chosen results.
4. `export_tour_gpx` uses MapKit's walking or cycling route geometry to save a GPX track under `~/Library/Application Support/LocalMacAppIntegrations/Tours/`. You can transfer and import that file into a compatible iPhone and Apple Watch route app.

The earlier `*_walking_tour*` tool names remain callable for existing clients but are superseded by the mode-aware names above. Tours saved before cycling support remain walking tours.

The server **does not track your phone or Watch location**. Supply a current address or coordinates for a live detour; the assistant can use `search_map_places` to resolve an address. To call these tools from ChatGPT on your phone while walking, use a remote connection to the Mac and keep the Mac and server running; the phone does not reach this loopback server directly. Tour files remain in Application Support and are never added to this repository. MapKit searches and route calculations use Apple's map service and require connectivity.

Apple Maps' documented URL format supports walking and cycling directions and waypoints, but iPhone Maps may not preserve every waypoint as a single custom tour. Check the link before setting off. The server cannot create a saved custom route inside Apple Maps or change navigation already running on Apple Watch. After a revision, open the new link and start the revised route yourself. GPX is an alternative for route apps that support importing tracks; the file is local to the Mac until you transfer it. Cycling directions depend on local MapKit coverage and may fail for a particular leg even in a generally supported country.

Timed event inputs use ISO 8601 with an explicit UTC offset, for example `2026-10-03T09:30:00+02:00`. Event searches need both start and end bounds. EventKit IDs can change when synced accounts replace an event. This version rejects edits and deletions of recurring events. The server returns an error if no destination list or calendar can be chosen unambiguously.

## Other devices and future hosting

For the ChatGPT phone app, [ChatGPT Remote](https://learn.chatgpt.com/docs/remote-connections) can use the MCP setup on an awake Mac running the desktop app and this server. A dedicated Mac can run it under a user account with Calendar and Reminders permissions. The current server cannot run as-is on a Cloudflare Worker because it depends on Apple's on-device EventKit framework.

Hosted ChatGPT Work/web access is a separate option using [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). See [remote access setup](docs/remote-access.md). The tunnel client is **not** part of `make run`.

## Privacy and limitations

The server has no bearer authentication. Any process on this Mac can reach its loopback endpoint while it is running; it is not accessible directly from another device or the internet. Do not change the listener to a LAN or public address without adding appropriate authentication. The server does not log reminder, calendar, or mail contents. Mail search and read results are passed to the MCP client when the tools are invoked.

To reset a denied macOS permission and get a new prompt:

```sh
tccutil reset Calendar com.localcalendar.mcp
tccutil reset Reminders com.localcalendar.mcp
```

Rebuilding the ad-hoc signed app may trigger a new permission prompt. `make clean` removes Swift build output. [PLAN.md](PLAN.md) records the original implementation plan.

## License

This project is available under the [MIT License](LICENSE). The adapted HTTP transport file retains the MCP Swift SDK's licensing terms and attribution; see [third-party notices](THIRD_PARTY_NOTICES.md).
