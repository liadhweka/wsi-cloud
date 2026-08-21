EFA-transport incident 2026-08-21 ~16:05-16:45Z (Leg B, i-006cc930fed5cf053):
All three seqw calibration cells (16 jobs x 4M direct, 300s) failed under sustained
bulk writes: fio err=35 (EAGAIN) + 'stuck grabbing stat_sem' (rep1 rc=134, rep2
rc=10), rep3 hung >3h on lost aio completions (wrapper then SIGKILLed during
recovery - no cleanup, no INDEX row; this note is its record). dmesg: efalnd
kefalnd_force_cancel_tx on BOTH efa_0/efa_1 to multiple OSS peers, ptlrpc bulk
timeouts, repeated OST connection lost/restored (last 16:45:08). EFA hw_counters
at 19:5xZ: retrans_pkts 17852(efa_0)+30104(efa_1), retrans_timeout_events
1011+1832 - SRD-level loss under load. The 19s stage-0 proof cell (15:46) and the
100MiB probes were clean; this box had never sustained full-rate EFA bulk before.
Diagnosis at write time: transport-level failure under sustained bulk writes -
STOP-and-surface per D16/L7 discipline. Never quote any rate from these dirs.
