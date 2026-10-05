# Using the menu bar app

The app runs in the current macOS user's graphical session and shows a ◷ menu bar icon. It is the place where the user chooses macOS access, enrolled clients, collection grants, bridge availability, and Launch at Login. The CLI runs locally on the same Mac; see [API and CLI](API.md).

## Enroll a client

1. In ◷ → **Open Controls…**, confirm Calendar and/or Reminders shows **Full access**. Use **List Calendars** or **List Reminder Lists** to inspect collection titles, IDs, and writability; the Clients & Permissions rows also show account/source. A name alone is not a stable target; the bridge uses the EventKit collection ID.
2. Open **Clients & Permissions…** and choose **New client**. Give the client a recognizable name. The app creates an Ed25519 credential file and shows the client UUID in the detail view; it confirms that the credential was saved but does not display its full path. Derive the path from the UUID using the pattern below. The new client starts with **zero** grants.
3. Select that client. Under the intended calendar or reminder list, check only the actions it needs, then choose **Save permissions**. Calendars offer Read, Create, Edit, Delete. Reminder lists add Complete. A read-only collection cannot receive write actions. Clearing all boxes for a collection removes its grant.
4. Enable the bridge in Controls or the Clients window. The app saves this on/off choice. A saved grant can be used while the bridge is active without a second app approval for each write, so choose grant scope deliberately.

The Clients window groups collections by account and displays each collection's ID and writable status. If an account disconnects or Full Access is lost, an unavailable saved grant remains in the registry rather than silently disappearing. Restore access and review it before use. Changes take effect immediately; a request already in progress may need to be sent again.

## Local credential and client life cycle

The app writes the private credential to the following path, using the lower-case client UUID shown in the UI:

```text
~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json
```

The directory is mode 0700 and the file is mode 0600. The file contains the client UUID and an `ekb_v1_` signing seed. The app stores only the matching public verifier, client metadata, grants, revision, and bounded activity history in `client-registry.json`. Pass the client's name or ID (`--client`) or the **file path** (`--credentials-file`) to `client.py`; never paste the seed into a command, chat, issue, screenshot, or repository. Anyone with the file and access to this macOS user account can sign requests within its current grants.

- **Rotate key…** replaces the app-managed credential file and verifier for the selected client. The old key stops working for future requests. Update any task that points to a moved or copied credential; the app cannot remove copies it does not know about.
- **Revoke…** invalidates that client's verifier and tries to remove the app-managed file. Check the UI result: a removal failure needs manual follow-up. Future requests and asynchronous replies that recheck the client revision are denied; revocation cannot undo a write that EventKit already committed.
- **Activity…** shows recent time, client ID, command, and outcome. It omits request parameters, titles, item contents, and keys. The registry retains at most 500 entries and the UI shows up to 100.
- **Disable** stops the local bridge and saves off; **Quit** stops the running process. Re-enabling is a local user choice.

An agent or script using a saved grant still needs authorization for the **particular user task** it is performing. The grant configures what the bridge permits; it does not create standing permission to make unrelated Calendar or Reminders changes.

## A safe first CLI check

After enrollment and bridge enablement, start with metadata and a bounded read from an empty temporary collection you own. Use the client name shown in the app, and the collection ID shown in the UI; do not inspect the credential contents:

```sh
python3 client.py scope_status --client "<client name>"
```

`--client` also accepts the client UUID. Clients can be renamed, so a script meant to last should use the UUID or the explicit key file path:

```sh
python3 client.py scope_status \
  --credentials-file "$HOME/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json"
```

`scope_status` returns the client's saved grants. `authorization_status` returns macOS Calendar and Reminders access. To read at most one reminder from a granted test list, pass the parameters on stdin so they need no temporary file:

```sh
echo '{"listID":"<ID of your temporary test list>","limit":1}' |
  python3 client.py read_reminders --client "<client name>" --params-file -
```

`python3 client.py --help` lists every command and the access it needs; `python3 client.py read_reminders --help` lists its parameters. Errors go to stderr with a short fix, and the exit code says what kind of problem it was (see [API and CLI](API.md)).

The client prints its response to the terminal; use only a terminal and log destination appropriate for the data. The bridge will return `forbidden` if the list has no Read grant. A safe synthetic **write** recipe and the complete parameter reference are in [API and CLI](API.md#synthetic-example).
