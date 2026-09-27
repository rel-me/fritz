# Integration services

These are reusable libraries. Importing them does not enable an integration or
create a listener in Fritz's desktop app. Hosts choose which settings pages and
services to expose, provide their own command policy, and retain their runtime
and credential identity. See [library APIs](libraries.md#shared-integrations).

## Local control contract

The shared client uses these relative paths under a host's versioned API. The
host authenticates all requests and wraps successes/errors in its own RPC
protocol. The Rust service accepts the corresponding `/v1/` path and returns the
success JSON value or an error preserving input, service, I/O and JSON failures.

| Operation | Method and path | Request / success payload |
| --- | --- | --- |
| WhatsApp status | `GET whatsapp` | `{connection: ...}` |
| Connect | `POST whatsapp/connect` | `{}` / `{connection: ...}` |
| Pause or resume | `POST whatsapp/enabled` | `{enabled: boolean}` / `{connection: ...}` |
| Remove account | `DELETE whatsapp/connection` | `{connection: ...}` |
| Refresh groups | `GET whatsapp/groups` | `{groups: [{id, name}]}` |
| Choose group | `POST whatsapp/destination` | `{id}` / `{connection: ...}` |
| Remote commands | `POST whatsapp/remote/enabled` | `{enabled: boolean}` / `{connection: ...}` |
| Claim command | `POST whatsapp/remote/claim` | `{}` / `{command: {id, text} or null, epoch}` |
| Reply | `POST whatsapp/remote/reply` | `{id, epoch, text}` |
| Send notification | `POST whatsapp/send` | `{text}` |
| Remote access status | `GET remote-access` | `{enabled, origin?, devices: [{id, name}]}` |
| Enable HTTPS | `POST remote-access/enable` | `{bind, origin, certificate, private_key}` |
| Disable HTTPS | `POST remote-access/disable` | `{}` |
| Generate pairing code | `POST remote-access/pair` | `{}` / `{code, expires_in}` |
| Revoke device | `POST remote-access/revoke` | `{id}` |

Certificate and private-key values are local PEM file paths. They are read by the
host agent, never accepted from a paired browser. The origin must be canonical
HTTPS, with no path, credentials, query or fragment, and match the listener port.
The host chooses routing; the library does not configure VPNs or expose ports.

WhatsApp remote commands are accepted only from the linked account in the saved
group, after remote control is enabled. History, future messages, stale commands,
duplicates and other members are rejected. Changing authorization invalidates
the inbox epoch. Claims are consumed before execution; uncertain sends are not
retried. Removing the connection deletes the integration's Keychain records.

The HTTPS dashboard uses host-provided assets. Mutations require the exact origin
and host-specific request header. Cookies are Secure, HttpOnly, SameSite=Strict
and use the `__Host-` prefix. Pairing attempts, devices, simultaneous connections,
request bytes, jobs and active executions have finite limits. Jobs and results
are scoped to the paired device. The host must validate an explicit command
allowlist and provide only the assets and reads it intends to expose.

## Service and MCP settings

`ServiceSettingsView` displays host-supplied process status, connection details,
recovery reports and a canonical RPC documentation link. The host supplies its
license action. It does not start or supervise a process.

`MCPSettingsView` exports client configuration and runs a connection check through
`MCPConnection`. Every MCP client launches its own adapter. The host continues to
own the MCP executable, tool catalog and canonical protocol documentation; this
library does not add a second MCP server or infer application-specific tools.
