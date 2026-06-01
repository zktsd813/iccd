# QEMU HMAT/CXL VMctl Notes - 2026-06-01

## Finding

The previous VM topology used two `memory-backend-ram` NUMA nodes without ACPI
HMAT performance information. With that setup, the guest kernel placed node0 and
node1 in the same default DRAM memory tier:

```text
/sys/devices/virtual/memory_tiering/memory_tier4/nodelist=0-1
```

This explains why memory-tiering-only NUMA balancing treated node1 as top-tier
DRAM and skipped top-tier page scans.

## QEMU Options

The local QEMU is 9.2.4 and supports the needed options:

- `-machine q35,hmat=on`
- `-numa node,...,initiator=0`
- `-numa hmat-lb,initiator=0,target=N,hierarchy=memory,data-type=access-latency,...`
- `-numa hmat-lb,initiator=0,target=N,hierarchy=memory,data-type=access-bandwidth,...`
- `-machine q35,cxl=on,cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=...`
- `-device pxb-cxl,...`
- `-device cxl-rp,...`
- `-device cxl-type3,volatile-memdev=...`

## vmctl Modes

`VM/vmctl.sh boot` now supports:

- `--slow-memory-mode numa`: previous default, regular RAM NUMA node1.
- `--slow-memory-mode host-cxl`: regular RAM NUMA node1 backed by host NUMA
  node2 CXL memory, plus HMAT latency/bandwidth for guest memory tiering.
- `--slow-memory-mode qemu-cxl`: CXL Type3 volatile memory backend plus HMAT.

Default mode is `host-cxl`. Legacy `hmat` is accepted as `host-cxl`; legacy
`cxl` is accepted as `qemu-cxl`.

## HMAT Validation

Booted a 2G/4G diagnostic VM with:

```bash
VM/vmctl.sh boot \
  --kernel linux-global-build/arch/x86/boot/bzImage \
  --rootfs experiments/20260601-pr-g29-global/images/tierdiag.qcow2 \
  --rootfs-format qcow2 \
  --root-device /dev/vda2 \
  --ssh-key /Serverless/Migration-friendly/qemu/tests/keys/id_rsa \
  --ssh-port 10104 \
  --name hmat-tierdiag \
  --fast-mem 2G \
  --slow-mem 4G \
  --fast-host-node 0 \
  --slow-host-node 2 \
  --host-cpus 0-3 \
  --guest-cpus 4 \
  --guest-node0-cpus 0-3 \
  --slow-memory-mode hmat \
  --accel kvm
```

Guest result:

```text
/sys/devices/virtual/memory_tiering/memory_tier4/nodelist=0
/sys/devices/virtual/memory_tiering/memory_tier56/nodelist=1
```

Relevant dmesg:

```text
ACPI: HMAT ...
acpi/hmat: Memory Flags:0001 Processor Domain:0 Memory Domain:0
acpi/hmat: Memory Flags:0001 Processor Domain:0 Memory Domain:1
Demotion targets for Node 0: preferred: 1, fallback: 1
Demotion targets for Node 1: null
```

## CXL Caveat

The current kernel config has `CONFIG_ACPI_HMAT=y`, but CXL drivers are mostly
modules:

```text
CONFIG_CXL_BUS=m
CONFIG_CXL_PCI=m
CONFIG_CXL_ACPI=m
CONFIG_CXL_MEM=m
CONFIG_CXL_PORT=m
CONFIG_DEV_DAX_CXL=m
```

So `--slow-memory-mode qemu-cxl` creates a QEMU CXL Type3 device, but the guest
needs an initrd with CXL modules or a kernel with CXL built in before relying on
the CXL memory being enumerated and onlined early. It should not be used for
performance measurements because the CXL Fixed Memory Window can route memory
access through QEMU emulation callbacks.
