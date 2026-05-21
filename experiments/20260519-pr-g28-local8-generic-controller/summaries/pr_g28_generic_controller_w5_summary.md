# PR g28 Generic Controller Check

Run: `20260519T074253Z-prg28-generic-controller`

Workload:

`/root/pr -f /root/gapbs_graphs/kron_g28.sg -i20 -t1e-4 -n3`

Configuration:

- local capacity: 8 GiB (`capacity_pages=2097152`)
- scan: 256 MiB, 1000 ms, fast scan off
- local fault sampling: 10%
- controller window: 5 s
- stop conditions:
  - local access >= 80% for 3 windows
  - residual remote ratio <= 20% for 3 windows

Result:

- controller stopped migration at 40.019 s, window 8
- stop reason: `local_access`
- `node_balancing` changed from 2 to 0
- PR read time: 28.42879 s
- PR trial times: 29.03247 s, 19.29321 s, 18.91010 s
- PR average time: 22.41193 s

The residual remote ratio condition did not trigger in this run. The final
triggering windows had local access at 100%, while residual remote ratio was
81.07% and 81.25% for the last two sampled windows.

Artifacts:

- `qemu-logs/20260519T074253Z-prg28-generic-controller/guest-artifacts/localutil-pr-generic2/controller.csv`
- `qemu-logs/20260519T074253Z-prg28-generic-controller/guest-artifacts/localutil-pr-generic2/workload.stdout.log`
- `qemu-logs/20260519T074253Z-prg28-generic-controller/guest-artifacts/localutil-pr-generic2/run_config.txt`
