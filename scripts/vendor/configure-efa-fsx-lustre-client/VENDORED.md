# Vendored: AWS official FSx-for-Lustre EFA client configuration bundle

- Source: https://docs.aws.amazon.com/fsx/latest/LustreGuide/samples/configure-efa-fsx-lustre-client.zip
  (linked from https://docs.aws.amazon.com/fsx/latest/LustreGuide/configure-efa-clients.html)
- Fetched: 2026-08-20 · zip sha256: ed421b0cd251f4dae78cc727f857937de345d7c67700cc240db5f6af7ba6ef49
- Contents unmodified. Vendored so a rebuild does not depend on the URL staying live or the
  content staying identical — this exact code is what the 2026-08-20 gated walk validated,
  and pinning it is what makes the next rebuild run *validated* code (pin versions that
  affect numbers). To upgrade: re-fetch, re-walk the gate, update the sha and this note.
- `scripts/wsi-lustre-phase2.sh` invokes `setup.sh` from here; it installs
  `/etc/systemd/system/configure-efa-fsx-lustre-client.service` (boot re-arm of the EFA LNet config).
