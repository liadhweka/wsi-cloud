# tmp/ — the human-transfer channel

Files here exist to move content between machines through git, because the human works across two
instances inside tmux buffers where copy-paste is impossible. Typical content: proposed terraform for the
laptop (Claude never runs terraform — these are proposals), config snippets, anything the human must carry.

Rules: transient by design — the human deletes a file once carried (or asks the session to); nothing here
is authoritative (the applied copy on the laptop is), nothing here is read by any script, and no benchmark
artifact ever lands here (those have their own homes: `runs/`, S3).
