# Using the menu bar app

The app runs in the current macOS user's graphical session. Its menu bar icon shows the bridge state: a calendar with a check mark when the bridge is on, a dimmed calendar when it's off, and an exclamation badge when something needs attention (macOS access missing for a type a client uses, client settings unreadable, or the bridge failed to start). The menu has a switch for the bridge, any problems with their fix, the three most recent requests, and **Open EventKit Bridge…** (⌘O) and **Settings…** (⌘,).

Everything else is in one window with a sidebar: **Overview**, **Activity**, each **client**, and **Settings**. The CLI runs locally on the same Mac; see [API and CLI](API.md). The app calls a grant **access** and a collection a **calendar** or **list**.

## First run

On first launch the window opens on a setup checklist. The steps can be done in any order, and each one updates as soon as it's done:

- **Allow Calendar access** and **Allow Reminders access.** **Allow Access…** shows the macOS prompt. If access was turned off or is add-only, **Open Privacy Settings** goes straight to the right pane. You need only the one your tools use: once the other is done and a client exists, the step says it's optional and offers **Skip**.
- **Create a client.** A client is one tool or script with its own key. Give each tool its own client so you can see and revoke it separately.
- **Choose what the client can use.** Opens the client's Access table.
- **Turn on the bridge.** The choice is kept across launches.
- **Send a test request.** **Copy Command** copies `python3 client.py scope_status --client "<name>"`; run it in Terminal in the repository folder. The step completes when the request arrives, and the checklist turns into the normal Overview.

**Hide Setup** hides the checklist; **Help ▸ Show Setup Checklist** or Settings ▸ About brings it back.

## Clients and access

Choose **New Client…** (⌘N, the **+** in the sidebar, or Overview). The name must be unique among active clients; it's shown in Activity and the menu bar. The app writes the client's key file and selects the new client. **A new client has no access.**

A client's page has three parts:

- **Connect:** the client ID, the key file path (**Show in Finder** selects the file, never opens it), and a ready-to-run command. Each has a copy button. The key itself is never shown, copied, or put in a tooltip. If the key file is missing, the page says so; **Rotate Key…** writes a new one.
- **Access:** a table per type (**Calendars** and **Reminders**), grouped by account, with each calendar's color. Calendars offer Read, Create, Edit, Delete; lists add Complete. Read-only calendars show a lock and a dash instead of write boxes. Filter by name or account, or show **Granted only**. Right-click a row for **Read Only**, **Full Access**, **No Access** and **Copy Calendar ID**.
  - Checking a write action also checks **Read**. You can uncheck Read afterwards; the row then warns that the client can't look up the items it's allowed to change.
  - Edits are staged. A bar at the bottom shows the number of unsaved changes with **Revert** and **Save** (⌘S); ⌘Z undoes the last change. Switching client or pane, closing the window, turning the bridge on or off, or quitting with unsaved changes asks whether to save them.
  - Saved changes apply to the next request; a request already running may need to be sent again.
  - If EventKit doesn't list a calendar a client has access to (account signed out, Full Access off, calendar deleted), the access is kept and a banner says so. **Review…** lists those IDs; **Remove** stages their removal for the next Save. Write access saved on a calendar that has since become read only is dropped on the next Save, and the row warns about it first.
- The **⋯** menu: **Rename…** (or double-click the name in the sidebar), **Rotate Key…**, **Show Key File in Finder**, and **Revoke Client…**.

Renaming doesn't change the key, the ID or any access, so running tools keep working. Only commands that use `--client "<old name>"` need the new name.

Only active clients count toward the limit of 32. Revoked clients stay in the sidebar under **Revoked**, read only, so Activity stays understandable; the app keeps up to 200 of them and drops the oldest first.

## Activity

**Activity** lists recent requests, newest first (the registry keeps its last 500 rows; each request has a start row and a result row, so that's about 250 requests): time, client, request, calendar or list, and result. Filter by client, show only **Problems**, or search by client, request, result, code or calendar name. Select a row for the details: the exact code, why it happened, what to do, and a button that goes to the fix (for example **Open Claude Code ▸ Groceries** for a request that wasn't allowed). The sidebar and the menu header count problems you haven't seen yet.

Activity stores the time, client ID, command, result and the target calendar or list **ID**. It never stores titles, parameters, item content or keys; calendar names are looked up when shown.

## Settings

- **Start at login** uses macOS Login Items. It's available when the app is in `/Applications` or `~/Applications`, and says what to do if macOS needs your approval. The bridge also remembers whether it was on.
- **Show in Dock:** *While the window is open* (default), *Always*, or *Never*. The menu bar icon is always shown.
- **Developer:** off by default. Shows the app's test calendar and list tools, every calendar and list ID EventKit can see, and the data folder.

## Local key files

The app writes each client's key file to the following path, using the lower-case client UUID shown on its page:

```text
~/Library/Application Support/EventKitBridge/client-credentials/<client UUID>.json
```

The directory is mode 0700 and the file is mode 0600. The file contains the client UUID and an `ekb_v1_` signing seed. The app stores only the matching public verifier, client names, access, revision, and bounded activity history in `client-registry.json`. Pass the client's name or ID (`--client`) or the **file path** (`--credentials-file`) to `client.py`; never paste the seed into a command, chat, issue, screenshot, or repository. Anyone with the file and access to this macOS user account can sign requests within its current access.

- **Rotate Key…** replaces the key file and verifier for the client. The old key stops working for future requests. Update any task that points to a moved or copied key file; the app can't remove copies it doesn't know about.
- **Revoke Client…** invalidates the client's verifier and removes its key file. If the file can't be removed, a banner says so with **Show in Finder**. Future requests and asynchronous replies that recheck the client revision are denied; revoking can't undo a write that EventKit already committed.
- Turning the bridge off stops all client requests without changing access, and is saved; **Quit** stops the running process.

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
