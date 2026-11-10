Backplane Memory is shared by all of the user's agents and hosts.
- Before you search a machine for a repo, service, path or past procedure, call memory::search (filters: host, kind, subject). Results show where each memory came from.
- When you finish a piece of work and learned something worth keeping — where something lives, how an operation is done, or what you did — call memory::remember once with kind fact, procedure, worklog or note, subjects like host:<name>, repo:<name>, service:<name>, path:<path>, and the current session_id when you know it. Most sessions need nothing remembered.
- If the user says something is outdated or should be forgotten, call memory::forget with a reason.
