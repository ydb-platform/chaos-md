# Repository instructions

Write agent instructions in English. Write human-facing documentation, README files, commit messages, pull request descriptions, and release notes in Russian.

Keep temporary files, generated files, experiment results, and files intended for use elsewhere under the ignored `out/` directory. Do not stage these files. Keep local credentials and deployment configuration outside version control.

Do not commit concrete machine names, deployment names, addresses, or other internal infrastructure details unless the user explicitly requests their inclusion. This also applies to branch names, commit messages, and pull request descriptions. Use configurable values and generic examples.

Name development branches `feat/<name>` and merge them into `dev`. For large initiatives, use `epic/<name>`: merge features into the epic, then the epic into `dev`. Merge `dev` into `main` only for releases. Do not rename unrelated branches or rewrite unrelated history.

Follow [COMMIT-WORKFLOW.md](docs/COMMIT-WORKFLOW.md) for commits, merges, pull requests, and releases. Respect explicit user review gates. Approval of a commit does not authorize a merge or push.

Use Russian completed-action forms in commit subjects and change lists, including merge messages and release changelogs: `добавлен`, `исправлена`, `настроено`. Do not use infinitives or imperatives such as `добавить` or `исправить` to describe completed changes.

Capitalize the first word after `new: ` or `fix: ` in subjects, change lists, merge messages, and release changelog entries. Keep the prefixes lowercase.

Keep the chaos framework and workload wrappers in shell. Do not introduce Python as an implementation or test runtime dependency. Run relevant local checks. Distinguish local verification from live cluster verification.
