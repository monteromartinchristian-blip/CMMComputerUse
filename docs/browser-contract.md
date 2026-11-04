# CMM Computer Use — Browser and downloads contract v1 (F-09)

Contract name `cmm-computer-use/browser`, version 1. It is advertised by
`bridge.ping` under `capabilities.browser` and `capabilities.downloads`. It
extends the [workspace contract](workspace-contract.md): every operation runs in
a context the caller owns. Every decision still goes through the policy grant at
the moment the operation runs.

Nothing here depends on a harness, a model provider or a browser vendor's
automation interface. The helper uses only:

- supported accessibility attributes and actions (`AXTabGroup`, `AXRadioButton`,
  `AXWebArea`/`AXURL`, `AXElementBusy`/`AXLoaded`/`AXLoadingProgress`,
  `AXSheet`, `AXDefaultButton`/`AXCancelButton`, `AXPress`, `AXValue`);
- file-system metadata (`lstat`) in directories the policy names.

It never uses:

- AppleScript, JXA or System Events;
- CDP, WebDriver or Marionette;
- synthetic keyboard or pointer input;
- cookies, history, keychains or browser profiles.

## 1. Policy

The download directories are part of the application grant:

```json
{"bundle_id": "com.google.Chrome", "scopes": ["observe", "control"],
 "downloads": {"roots": ["~/Downloads"]}}
```

- **No roots, no downloads.** A grant without `roots` watches nothing and answers `DOWNLOADS_NOT_ENABLED`.
- **Roots are exact.** A subdirectory is not implied.
- **Malformed roots invalidate the policy.** A relative path, `..`, or `/` makes the whole policy invalid, and the helper denies everything.
- **Window patterns follow the page title.** A browser grant should normally not restrict windows by title. If it does, a tab switch that renames the window out of the pattern stops control, and that is the correct behaviour.
- **macOS may need its own permission.** Reading `~/Downloads` can require macOS's Files and Folders permission for the helper. Without it the answer is `DOWNLOAD_ROOT_UNAVAILABLE`, never a guess.

## 2. Windows, tabs and pages

`browser.state {context_id}` is read-only and needs the `observe` scope. It returns, for each window of the context's browser:

- **Window identity:**
  - `window_key`, stable while the window lives;
  - `window_id`, the CGWindowID when it can be matched unambiguously;
  - `authorized`. A window outside the grant is listed with no title and no tabs.
- **Tabs:**
  - `tabs[]`, each with `tab_id`, `index`, `title` and `selected`, plus an `identity` field set to `element`, `title` or `new`;
  - `tabs_exposed`. A window with no tab strip is one implicit tab;
  - `opened_tabs` and `closed_tabs`;
  - `tab_selection_changed`.
- **Page:**
  - `page.url`, redacted: scheme, host, port and path only. No query, no fragment and no credentials ever leave the helper;
  - `page.document`, a digest;
  - `page.load`: `loading`, `loaded` or `unknown`. `unknown` is never reported as loaded;
  - `page.pdf`.
- **Dialogs:** `dialog_open`, meaning a sheet is open, usually a save dialog.
- **Transition:** what changed since this context last looked, with `kind`, `meaning`, `context_survives` and `handles_invalidated`.

| `transition.kind` | Context survives | Meaning |
|---|---|---|
| `unchanged` / `loading` | yes | handles stay valid |
| `tab_switched` | yes | another tab is selected; **not a disconnection** |
| `navigated` / `reloaded` | yes | the document changed; old handles are refused |
| `tab_closed` / `window_closed` | yes | the browser is still running |
| `app_relaunched` / `app_closed` | no | the browser was restarted or closed |

Tab ids follow the accessibility element: a title change or a reorder keeps the id. A unique title is used only when there is no element evidence. A closed tab's id is never reused.

`browser.wait {context_id, until: settled|loaded|changed, timeout ≤ 120}` is read-only. It polls the same facts every 250 ms and takes the helper lock for one sample at a time, never for the whole wait. It also reports `intermediate_documents`, the number of redirects or intermediate pages passed through.

Window targeting:

- `observation.describe` accepts `window_id`.
- An explicit context keeps observing the window it observed last instead of following focus. `window_follow` in the observation says which applied: `requested`, `bound`, `bound_window_closed` or `focused`.
- Two contexts can follow two windows of one browser.

## 3. Actions

These are two new kinds of `action.execute`, both in the accessibility class. They go through the full pipeline: mode, grant (`control`), breach latch, interference sampling and op-id ledger. They are mutating and are never resent automatically.

- `browser.select_tab {context_id, tab_id}` presses the tab with `AXPress`, falling back to `AXSelected`. It then verifies on the tab strip that the tab is selected. Refusals:
  - `TAB_UNKNOWN` when the tab is gone;
  - `COMPUTER_PERMISSION_DENIED` without Accessibility.
- `browser.save_dialog {context_id, filename?, confirm=true, overwrite=false, cancel=false}` works on the sheet of the context's window:
  - the name field is NSSavePanel's `saveAsNameTextField`, or the only text field;
  - confirm and cancel are the sheet's default and cancel buttons;
  - the file name is one plain path component and is verified by reading it back;
  - if an "already exists" alert appears, the helper stops with `reason=name_conflict` and the dialog stays open;
  - `overwrite=true` presses Replace only when the button is positively identified by its localized title. Otherwise the answer is `reason=replace_unidentified` and nothing is replaced;
  - the destination folder is the one the dialog shows. Navigating the dialog to another folder is not part of v1.

## 4. Verified downloads

Pressing a download control proves nothing. A download is `complete` only when all of these hold:

- the finished file exists in the directory;
- it is non-empty;
- its partial file is gone;
- its size and modification time held steady for the settle interval (1 s).

| Operation | Class | What it does |
|---|---|---|
| `download.expect {context_id, directory?, name_hint?, op_id, expected_bytes?, expected_sha256?}` | idempotent (same `op_id` returns the same expectation) | Baseline of the directory **before** the trigger. Returns `download_id` and status. |
| `download.status {download_id, checksum?}` | read | Scan and state. `checksum: true` adds `sha256` and is the only time the file's bytes are read. |
| `download.wait {download_id, until: terminal\|started, timeout ≤ 120}` | read | Bounded wait outside the helper lock. |
| `download.list` / `download.forget` | read / idempotent | The caller's own expectations only. |

States:

- `not_started`;
- `in_progress`, with bytes so far;
- `interrupted`: no growth for 20 s and the partial file still exists, so `resumable` is true. It goes back to `in_progress` if the download grows again, and `resumed` is reported;
- `failed`: the partial file vanished and no finished file replaced it;
- `complete`, with `file_name`, `path` and `bytes`.

Every status also reports:

- `renamed`: the browser picked another name, typically `name (1).ext`;
- `replaced_existing`;
- `partial_format`.

Partial formats followed. Renames are tracked by inode first, then by the announced final name:

| Engine | In progress | Finished |
|---|---|---|
| WebKit (Safari) | `Name.ext.download/` (bundle) | `Name.ext` |
| Chromium (Chrome, Edge, Brave…) | hidden temp file → `Name.ext.crdownload` (or `Unconfirmed N.crdownload`) | renamed in place |
| Gecko (Firefox) | `Name.<8 random>.ext.part` plus a 0-byte `Name.ext` placeholder (older releases: `Name.ext.part`) | the part file renamed over the placeholder |

The Chrome and Firefox rows were observed live; see the report. Two expectations in one directory never share a download:

- each new artifact is claimed by one expectation whose baseline predates it;
- a name hint is preferred, otherwise the oldest expectation wins;
- a download already running when an expectation is declared is never credited to it.

**Truncated files a browser treats as finished.** In the live lane, Firefox
turned a transfer cut at 300 kB of 2 MB into a finished-looking `cut.bin`.
File-system metadata cannot tell that apart from a real download. Without
`expected_bytes` or `expected_sha256`, `complete` therefore means "the browser
finished writing a non-empty, stable file". With them:

- the wrong size is reported as `failed` with `reason=size_mismatch`;
- the wrong hash is reported as `failed` with `reason=checksum_mismatch`. A
  declared hash is an explicit request to read the file.

**Archives unpacked by the browser.** With "Open safe files after
downloading", Safari unpacks a ZIP into a folder and deletes the archive
(observed live). The download is reported `complete` with:

- `extracted_by_browser: true`;
- `archive_name`;
- `extracted_to`;
- `path`, pointing at the folder.

**The root must be the browser's real folder.** The helper cannot read browser
settings. A Safari that saves to iCloud Drive › Downloads needs that folder as
its root.

**Lost answers.** If a trigger press returns `OUTCOME_UNKNOWN`, the client does not press again. It asks the expectation whether a download started.

## 5. Client rules (adapter `browser.py`)

- **`download_by_pressing`:**
  1. declare the expectation;
  2. press once;
  3. wait until the download starts, then until it ends.

  If nothing started, it reads `browser.state` and tells the caller what blocked it: a save dialog, the PDF viewer, or nothing. It never presses again.
- **`classify_failure`** names what went wrong:
  - `connection_lost` and `helper_restarted`;
  - `outcome_unknown`;
  - `tab_switched`, `navigated` and `document_changed`;
  - `window_closed` and `app_closed`;
  - `tab_unknown`, `refused` and `other`.
- **Automatic re-observation.** An element action refused because the page or tab changed gets a fresh observation of the same context appended. This is a read; the action is not repeated. A closed window or a lost answer is not auto-observed.

## 6. MCP tools (adapter)

| Tool | Read-only | Wraps |
|---|---|---|
| `computer_use_browser_state` | yes | `browser.state` |
| `computer_use_browser_wait` | yes | `browser.wait` |
| `computer_use_browser_select_tab` | no | `browser.select_tab`, then wait and observe |
| `computer_use_download` | no | `download_by_pressing` |
| `computer_use_download_expect` | yes (bookkeeping) | `download.expect` |
| `computer_use_download_status` | yes | `download.status` / `download.wait` |
| `computer_use_save_dialog` | no | `browser.save_dialog` |

All of these are available in `background` mode. The server instructions tell the model to use them without being asked, and:

- to treat a tab switch or navigation as normal;
- never to claim a file was downloaded without `state=complete` and its path.

## 7. Errors (additions)

| Code | Meaning |
|---|---|
| `CONTEXT_UNOBSERVED` | the context is bound to no browser yet |
| `TAB_UNKNOWN` | the tab is no longer open |
| `SAVE_DIALOG_NOT_FOUND` | no sheet on the window |
| `DOWNLOADS_NOT_ENABLED` | the grant declares no download directory |
| `DOWNLOAD_ROOT_NOT_ALLOWED` | the directory is not one of the grant's roots |
| `DOWNLOAD_ROOT_UNAVAILABLE` | the directory cannot be read (missing, or not permitted by macOS) |
| `DOWNLOAD_UNKNOWN` | no such expectation for this client |
| `DOWNLOAD_LIMIT` | too many open expectations (8 per client, 32 in total) |
