# Local Reminders and Calendar MCP — implementation plan

## Goal

Build a small MCP server that runs on this Mac and lets an MCP client list, search, create, update, and delete items in Apple Reminders and Calendar. Email is out of scope for this first version.

## Important ChatGPT connection constraint

The ChatGPT desktop app can connect directly to a local MCP server using stdio or Streamable HTTP. Hosted ChatGPT Work/web uses a remote connection and does not read the desktop app's local MCP configuration. OpenAI Secure MCP Tunnel connects a private server on this Mac to hosted ChatGPT without exposing it to the public internet.

The current server exposes Streamable HTTP on loopback (`127.0.0.1`). Both ChatGPT desktop and the official tunnel client can use that endpoint. `make run` starts the Swift server; the tunnel client is a separate process after one-time Platform and workspace setup. Stdio can be added later if a private child process is preferable. Do not expose an unauthenticated HTTP listener on the LAN or public internet.

## Recommended implementation

- **Language/API:** Swift 6 with Apple EventKit and the official MCP Swift SDK. EventKit directly reads and changes Calendar and Reminders data, including items synced from configured accounts.
- **Process shape:** A compact Swift executable packaged with an app bundle and an `Info.plist` that supplies the Calendar and Reminders privacy usage descriptions. This gives macOS a clear application identity for permission prompts. The executable runs as a local MCP server; `make run` launches it.
- **Transport:** MCP Streamable HTTP bound only to `127.0.0.1`, for use through Secure MCP Tunnel. Keep transport and EventKit operations in separate modules so stdio can be added without duplicating business logic.
- **Minimum OS:** macOS 14 or newer, using the current full-access EventKit APIs. Confirm the actual Mac version before implementation; if older macOS support is needed, adjust the permission API and usage-description keys.
- **Access:** Request full Reminders access and full Calendar access only when the corresponding tools are first used. Read access is needed to search and update existing entries; EventKit does not offer read-only access for these item types. Explain this in the permission descriptions and setup guide.

## Initial MCP tools

Expose small, explicit operations rather than a single general-purpose command:

### Reminders

- `list_reminder_lists` — return available lists and stable identifiers.
- `search_reminders` — search a selected list or all lists; allow filters for completion state and due-date range; return stable ID, title, notes, due date, completion state, list, and modification date.
- `create_reminder` — create a reminder with title, optional notes, due date, priority, and destination list.
- `update_reminder` — update specified fields by stable reminder ID; leave omitted fields unchanged.
- `delete_reminder` — delete one reminder by stable ID.

### Calendar

- `list_calendars` — return available calendars and stable identifiers.
- `search_events` — require a bounded date range; optionally filter by calendar and text; return stable ID, title, start/end, all-day flag, location, notes, calendar, and recurrence summary.
- `create_event` — create an event with title, start/end, optional all-day flag, location, notes, and target calendar.
- `update_event` — update specified fields by stable event ID. Require an explicit scope when an event is recurring; for the first version, reject recurring-event edits rather than risk changing multiple occurrences.
- `delete_event` — delete by stable ID. Require an explicit scope for recurring events; initially reject recurring-event deletion.

Use ISO 8601 timestamps with explicit offsets for timed events. Return clear errors for missing permissions, invalid dates, unavailable calendars/lists, stale IDs, and unsupported recurring changes. Do not silently choose a destination when there is no unambiguous default; return available choices instead.

## Safety and data boundaries

- Keep the listener on loopback and route remote ChatGPT access only through the supported secure tunnel.
- Request each EventKit permission separately and only when that data type is first used.
- Keep MCP protocol messages on stdout only if stdio is implemented; send diagnostics to stderr. For HTTP, avoid logging event/reminder contents.
- Writes must name the target item and show the resulting item ID and updated fields. Deletes operate on one explicit stable ID.
- Do not read or write EventKit's private database files directly.
- No email access, background sync, or broad natural-language date parsing in version one.

## Implementation sequence

1. Confirm macOS version and whether the intended host is ChatGPT desktop directly or hosted ChatGPT Work via Secure MCP Tunnel.
2. Create the Swift package, MCP server entry point, EventKit service layer, app-bundle metadata, and `Makefile` targets (`build`, `run`).
3. Implement permission status/request handling and the list/search read tools for both data types.
4. Implement create/update/delete operations with input validation and explicit recurrence safeguards.
5. Document first-run permissions, build/run steps, direct desktop connection, tunnel prerequisites for hosted Work, and how to reset macOS permissions if access is denied.
6. Add the optional stdio transport only if a private child process is preferable to the current local HTTP endpoint.

## Acceptance criteria

- `make run` starts the MCP server on loopback and it remains available until stopped.
- The MCP client can discover the tools and receive useful permission/setup errors.
- The user can read, create, edit, and delete reminders and events in the native Apple apps through the exposed tools.
- Changes made through the server appear in Calendar/Reminders and changes made in those apps are visible on the next search.
- ChatGPT desktop can connect directly to the local HTTP endpoint. Hosted ChatGPT Work connectivity is documented as requiring Secure MCP Tunnel and separate Platform/workspace access.

## References

- [Apple EventKit](https://developer.apple.com/documentation/eventkit/ekeventstore)
- [Apple: Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [OpenAI: Developer mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt)
- [OpenAI: Local MCP configuration](https://learn.chatgpt.com/docs/extend/mcp)
- [OpenAI: Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
