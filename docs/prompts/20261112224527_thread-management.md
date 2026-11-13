# User request

- Add thread archive and deletion...
- Handle project directories not being available... if so the project and threads are disabled and a small "Fix" button is offered.. It can recreate it or select another directory

# Delegated prompts

Implement ProjectsSidebar UI for archive/restore/delete with deletion confirmation, toggle showing archived threads, unavailable project disabled thread rows and small Fix button offering recreate or choose folder. Own only ProjectsSidebar.swift. Coordinate store APIs: isAvailable(project), setArchived(id, Bool), deleteThread(id), repairProject(id,directory: URL? = nil) throws (nil recreates). archived property ProjectThread isArchived Bool. Use sheet for repair or menu with recreate/select. Read swiftui skill. Do not commit.

Review final diff read-only for correctness; identify lifecycle/selection issues. Do not edit while make test running. Focus archive selection hidden when toggle off, unavailable disabled rows. Root handles fixes.

Moved work to /Users/gabe/projects.next/Fritz-thread-management because another active task was switching the original checkout's branch. All further work must use the isolated checkout.

Final read-only review delegation: In isolated checkout /Users/gabe/projects.next/Fritz-thread-management, review production and new WorkspaceTests diff. Verify atomic archive, availability refresh, folder repair cache replacement, deletion race and menu enablement. Do not edit; tests compiling. Send only actionable findings.

PR monitoring delegation: Monitor the published PR checks in this isolated checkout. Investigate failures and fix failures attributable to this change, preserving unrelated work. If code changes, run affected checks, commit, push, and monitor the new head again. Report all check results and exact blockers.
