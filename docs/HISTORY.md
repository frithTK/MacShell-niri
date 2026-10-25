# Source history

MacShell-niri 1.0.0 starts a new Git history with one initial release commit. Earlier development commits, imported upstream tags and the preliminary release have been removed from the active repository references.

The complete previous history was saved in a private Git bundle before the reset. Its restoration was checked against the original main commit, tree and 140-commit history. Release metadata and the original reference list were saved alongside it. The archive is kept by the maintainer outside the repository and release downloads.

The port is based on [0-ss/MacShell](https://github.com/0-ss/MacShell) at upstream commit [`dbaf3f4`](https://github.com/0-ss/MacShell/commit/dbaf3f4). Rickky's original code, artwork attribution and MIT copyright notice remain in the source and [LICENSE](../LICENSE). The history reset does not change their origin or license.

Development notes and performance reports may still name commits from the archived history. Those identifiers record the source used for the original checks.

## Existing checkouts

Because the new main branch has a different root, clone a fresh checkout for 1.0.0. Keep the old directory until any local changes have been moved across. Existing installed settings do not need to be reset.

[Install or update](INSTALL.md) · [Установка и обновление](INSTALL.ru.md)
