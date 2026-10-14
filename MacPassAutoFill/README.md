# Native Password AutoFill

macOS 13+, off by default (Settings → Integration). The extension is a sandboxed
picker without KeePassKit, keys or database access. All data comes from the
running MacPass over a Unix socket in the App Group container
`<Team ID>.MacPass.AutoFill`. The socket is named after MacPass's bundle
identifier (`af-<first 12 hex digits of its SHA-256>.sock`), so builds with
other identifiers never share a listener.

## Components

- `MPAutoFillServer` (host): socket listener, peer validation, catalog scoping
  and single-use grants.
- `MPAutoFillCoordinator` (host): picks the active database, builds the catalog,
  resolves references and is the only writer of `ASCredentialIdentityStore`.
- `MacPassAutoFill.appex`: account picker, owner authentication, unlock handoff.
  - `CredentialProviderViewController`: the request flow and the system
    presentation/completion calls.
  - `MPAutoFillRequestState`: the single source of truth for one request and
    the resources it owns (grant, subscription, authentication, timer).
  - `MPAutoFillPickerView`: layout and user input only; holds no request state.
- `AutoFillShared`: protocol values, framing, request validation, peer checks
  and host matching.

## Data exposure

- Only the **active database** takes part: the most recently focused document
  window, else the frontmost one. It must be unlocked and free of an unresolved
  external change. Other databases contribute nothing: no titles, usernames,
  hosts or database names.
- The identity store holds host and username only. Locking republishes it at
  once; other edits are coalesced for 0.5 s.
- With the feature off and no identities left to clear, MacPass touches neither
  the socket nor the identity store.
- "Show all entries" never sends the whole database: a catalog lists at most
  100 accounts, and search runs in MacPass.
- Sites match by host (and its `www.` variant) regardless of scheme and port.
  Invalid URLs and ports never produce identities.
- Passwords never appear in catalogs or identities. After owner authentication
  the selected password is resolved again from the live database and sent once;
  the extension never caches it.

## Security model

- Both sides validate the peer by audit token against
  `anchor apple generic and identifier X and certificate leaf[subject.OU] = TEAM`.
  There is no unsigned fallback. The signature is taken from the kernel, since
  the sandboxed extension may not be able to read MacPass's executable.
- Owner authentication (Touch ID / password) runs in the extension, which the
  host cannot verify. MacPass therefore accepts only an extension with hardened
  runtime, without `get-task-allow` and without an attached debugger, and logs
  `hardened-runtime` when it refuses one.
- A same-user process can occupy the socket path while MacPass is not running.
  The extension rejects it by signature, and MacPass replaces any listener that
  is not a signed MacPass. Remaining risk: same-user denial of service.
- Per bundle identifier, one MacPass instance listens and writes the identity
  store; another takes over after it quits.
- MacPass plugins run inside the host and can read unlocked databases
  regardless of AutoFill.
- The activation URL (`<bundle id>.autofill://open`) can be opened by any app or
  web page. It only brings a running MacPass forward and never names files or
  returns data.
- Events travel only over the validated socket, never as Darwin or distributed
  notifications that other processes could post or observe.

## Protocol

Length-prefixed binary property lists, at most 1 MiB per frame, validated on
both ends.

- `catalog` with one scope: `services` (the requesting sites), `record` (a
  selected system suggestion) or `all` (only after owner authentication; the
  following fill may reuse it for 60 s). An optional `query` narrows a list by
  title, user, database name and host. Lists hold at most 100 accounts and set
  `more` when further accounts match.
- `credential` with `record`: the host re-checks the live entry against what
  the picker displayed and returns the password, or `stale`.
- `unlock`: shows the active database's unlock view once the activation URL has
  brought MacPass forward.
- `cancel`: releases the request's grant.
- `subscribe`: an authenticated connection that only receives `invalidate` and
  `catalogChanged` events. Closing it unsubscribes.

A `ready` or `locked` catalog leaves a grant bound to the request ID and the
caller's audit token for 120 s; `credential`, `unlock` or `cancel` consumes it.
Locking, switching the active database, disabling the feature and sleep revoke
all grants and invalidate subscribers.

Status values: `ready`, `locked`, `conflict`, `disabled`, `noDocuments`,
`tooLarge`; only `ready` carries entries.

System suggestions return `userInteractionRequired`, so Safari receives a secret
only after authentication in the provider UI. Filling another site's account
asks for a confirmation whose default button is Cancel.

## Values and placeholders

Excluded: trashed, expired and template entries, and groups with searching
disabled. Only `{REF:P@I:<entry UUID>}` references are resolved. Search
references, unresolved or cyclic references and any placeholder KeePassKit would
substitute (plus `{PICKCHARS}`, `{PICKFIELD}` and OTP tokens) make the entry
unavailable. Unknown `{tokens}` are literal text, as in KeePass.

## Identity publication

The host replaces the whole identity index after relevant changes instead of
updating it incrementally; with a single active database this keeps lock, switch
and crash recovery simple. Identities left behind by a crash are cleared or
replaced on the next launch.

## Building and testing

Signing is described in the root README (`.local-build.xcconfig`). Ad hoc builds
compile and run tests but are never activated by macOS as a provider.

Protocol, framing, host and extension logic run in `MacPassTests`. Platform
behavior (Safari fill, authentication, unlock handoff) needs a signed build and
a manual check against a local sign-in page and a test database:

- A client that connects to the socket and is ad hoc signed, signed by another
  team, or signed by the development team with a different identifier must
  receive no reply. MacPass logs `validate-peer` each time.
- A Debug extension with `get-task-allow`, or one built without hardened
  runtime, must be refused with `hardened-runtime`.
- Lock or switch databases during the picker and authentication, unlock while
  the panel stays open, cancel and reopen repeatedly, quit MacPass. Rows must
  clear on invalidation or disconnect, and an external unlock must not fill by
  itself.
