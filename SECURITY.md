# Security Policy

This repository holds the RouterChat installers, the updater, and the install site. The full policy, including scope, supported versions, response times, and what not to include in a report, lives at [routerchat/SECURITY.md](https://github.com/echo1097/routerchat/blob/main/SECURITY.md).

Report security issues through GitHub private vulnerability reporting, either here through this repository's **Report a vulnerability** button or in the [main repository](https://github.com/echo1097/routerchat/security/advisories/new). Installer, updater, and install site issues are welcome in either place, and both reach the same maintainer.

Private reporting is the only accepted channel. Do not open a public issue for a security problem in either repository.

Never include `user-data/.env` or `user-data/routerchat.sqlite3` in a report. The first holds your OpenRouter API key and the second holds your chats and stories.
