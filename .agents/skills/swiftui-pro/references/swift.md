# Swift correctness

Separate user-facing formatting/search from protocol serialization and exact
identifier matching. Localization advice must not change API bytes, stable IDs,
file paths, or machine-readable logs. Choose comparison and formatting semantics
from the caller's contract, not a universal API preference.

Trace optionals and errors to reachable inputs. Flag a forced unwrap or swallowed
error when the failure is plausible and explain its impact. Preserve cancellation
as distinct from a user-action failure; use the existing feedback channel rather
than adding alerts to every catch block.

Do not report Date initializer spelling, numeric type aliases, shorthand syntax,
explicit imports, or helper extraction as correctness problems. For async work,
use [Fritz concurrency](concurrency.md); existing queues and locks can be legitimate
parts of a documented native boundary.
