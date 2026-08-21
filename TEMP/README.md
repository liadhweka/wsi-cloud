# TEMP/ — the human-transfer channel

Files here exist to move content between machines and sessions through git, because the human works across
two instances inside tmux buffers where copy-paste is impossible. Typical content: proposed terraform for
the laptop (Claude never runs terraform — these are proposals), rebuild handoff prompts, notes for the
other leg's session, config snippets — anything the human must carry.

Named `TEMP/`, not `tmp/`: a repo dir called `tmp/` collides with system `/tmp` in conversation — and
system `/tmp` here is sandbox-private per Claude session, so content parked there is invisible to everyone
else. The unambiguous name prevents the wrong destination.

Rules: transient by design — a file is deleted once carried or once its session has executed it (spent
once read); nothing here is authoritative (the applied copy on the laptop is); no script depends on this
dir to run (the teardown preflight only scans it, warn-only, for a handoff prompt); no benchmark artifact
ever lands here (those have their own homes: `runs/`, S3). **Anything written here is committed and pushed
in the same work block** — an unpushed note is invisible to the machine it is for.
