# Local Mac App Integrations MCP

A small MCP server for Apple Calendar and Reminders, plus read-only access to one iCloud Mail account configured in Apple Mail. It uses Swift, EventKit, Apple Mail automation, and the MCP Swift SDK.

## Start it

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode Command Line Tools).

From this folder, run:

```sh
cp .env.example .env
# Edit .env once to set your iCloud Mail address.
make run
```

The `.env` setup is one time only; on the original development Mac it is already configured. The file is Git-ignored and contains the address of the Apple Mail account the Mail tools may access. It does not need a password. Leave the Terminal window open while using the tools. Press Ctrl-C to stop the server. `make run` builds an app bundle and starts the MCP endpoint at `http://127.0.0.1:8765/mcp`. It listens only on this Mac's loopback interface. **No tunnel client is needed for the local ChatGPT desktop app.**

The first Calendar or Reminders tool call may trigger a macOS permission prompt. Grant access to both when prompted. If access was previously denied, enable **Local Calendar MCP** in **System Settings → Privacy & Security → Calendars** or **Reminders**. The generated app bundle carries the permission descriptions; launch the server through `make run` rather than running the bare Swift binary.

Mail search requires the address in `.env` to be configured and enabled in Apple Mail. The first Mail tool call may ask you to allow macOS Automation access to Mail. Check **System Settings → Privacy & Security → Automation** if you denied it. No iCloud password is stored in this project. Mail tools are scoped to this account; other Mail accounts are not searched. Search covers message subjects and senders across its mailboxes, then `read_icloud_mail` retrieves one selected message's text body. Full-text body search is not included.

## Connect ChatGPT on this Mac

In the ChatGPT desktop app, add an MCP server in **Settings → MCP servers** using **Streamable HTTP** and the URL `http://127.0.0.1:8765/mcp`. Save and restart ChatGPT if prompted. This is a one-time setup. With `make run` running, try “List my reminder lists” or “List my calendars.”

The local connection is already configured on the original development Mac as `local-mac-app-integrations`. On another Mac, add it there separately.

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
