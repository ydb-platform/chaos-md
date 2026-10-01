# Commit and release workflow

This is a reusable agent instruction. Write human-facing messages in Russian.

## Commit messages

Use a short first line that states the substance of the change. If a commit is entirely or predominantly a bug fix, prefix its subject with `fix: `. Do not prefix enhancement subjects with `new: `; enhancement is the default.

When a body helps explain the change, add a blank line and a list of specific changes. Prefix each item with `fix: ` for a fix or `new: ` for an enhancement. Describe the resulting behavior, not the sequence of attempts.

Describe completed changes in both subjects and body items. Use Russian completed-action forms such as `добавлен`, `исправлена`, `настроено`, or `реализованы`. Do not use infinitives or imperatives such as `добавить`, `исправить`, or `настроить`. Apply the same rule to merge messages and release changelog entries.

Capitalize the first word after `new: ` or `fix: ` in subjects, change lists, merge messages, and release changelog entries. Keep the prefixes lowercase.

```text
Добавлены генератор нагрузки и мониторинг

- new: Добавлены настройка и запуск генератора нагрузки.
- new: Добавлен отдельный дашборд для экспериментов.
- fix: Исправлено сохранение состояния воздействия при недоступности удалённого хоста.
```

## Review before committing

Inspect the staged file list and staged diff. Exclude temporary files, experiment results, generated artifacts, credentials, and unrelated changes. Do not expose concrete hosts, deployment names, or internal infrastructure details unless explicitly authorized. Verify all claims and run relevant checks.

## Merge messages

Include a change list in merge commit bodies. Derive it from the net change of the complete increment against the target branch. Do not concatenate commit bodies: they may repeat changes or describe intermediate behavior later reversed. Omit claims that cannot be confirmed from the final increment.

## Releases

Prepare the changelog from release commits and reconcile duplicates and reversals against the final release diff. An operator must review the changelog before publication because it is visible on the release website.

## Approval gates

Follow the user's requested approval sequence. If separate approvals are requested for the feature commit, merge commit, and push, present each concrete result at its own gate. Approval of an earlier action does not authorize later actions.
