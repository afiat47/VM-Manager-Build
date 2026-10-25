# VM-Manager-Build

Builds the VM Manager installer ISO: Ubuntu Server 24.04 that, once installed on a bare-metal
server, sets up Kubernetes, KubeVirt, Rook-Ceph and VM Manager **without any internet access**.
Everything is driven by `m.sh`:

```bash
./m.sh help
./m.sh all                 # build everything and produce output/vm-manager-<version>-<id>.iso
```

## Build Guide

### Prerequisites

The build machine needs internet; the servers installed from the ISO don't.

| | Windows | Linux |
|---|---|---|
| Shell + git | Git for Windows (run from Git Bash) | bash, git, curl |
| Container engine | Docker Desktop, running | docker (podman: `KUBEVIRT_CRI=podman`, KubeVirt only) |
| Memory for the container engine | 8 GB or more | 8 GB or more |
| Disk | ~60 GB free for Docker's disk image, ~30 GB for this folder | same |

The `apps/*` folders must be git checkouts (keep their `.git` folders when copying the project).
Compilers, Bazel, Go, Java and Node all run inside containers; nothing else has to be installed.

### How it fits together

```
apps/kubevirt ───./m.sh kubevirt───► docker/images/kubevirt/*.tar   manifests/kubevirt/
apps/rook ───────./m.sh rook───────► docker/images/rook/*.tar       manifests/rook/
apps/VM-Manager ─./m.sh vm-manager─► docker/images/vm-manager/*.tar manifests/vm-manager/
(internet) ──────./m.sh deps───────► cache/deps/   .debs, containerd, Calico, CDI, Ceph, ... images
                                            │
                 ./m.sh bundle ─────► bundle/      everything above, checked for completeness
                 ./m.sh iso ────────► output/vm-manager-<version>-<bundle id>.iso
```

- Each app builds independently; after changing one app, rebuild only that one, then run
  `./m.sh bundle` and `./m.sh iso`.
- Builds read the sources from a git snapshot (HEAD + uncommitted changes to tracked files),
  never from the working folder. **Brand-new files must be `git add`-ed** (no commit needed).
- The ISO contains build results only (image tarballs, manifests, packages, the installer),
  no source code. Servers build nothing.

### Versions

All versions are pinned in [versions.env](versions.env): Ubuntu, Kubernetes, containerd, Calico,
CDI, Ceph, ... and the release each `apps/` source tree must be based on. Every step reads it,
and so does the installer on the server. To change a version:

1. Edit `versions.env`.
2. `./m.sh deps --lock` re-resolves every image tag to its digest in
   [versions.lock](versions.lock). Without `--lock`, `./m.sh deps` downloads exactly the locked
   digests, on any build machine, at any later date.
3. Rebuild (`./m.sh all`).

How each kind of version is fixed:

| What | Pinned by |
|---|---|
| Container images | tag + digest (`versions.lock`) |
| Ubuntu packages | `UBUNTU_SNAPSHOT`: the archive as it was at that moment (snapshot.ubuntu.com) |
| Kubernetes packages | exact version from pkgs.k8s.io |
| Ubuntu ISO, containerd, runc | SHA256 checksums |
| `apps/kubevirt`, `apps/rook` | must be based on `KUBEVIRT_VERSION` / `ROOK_VERSION`; the build stops otherwise |

The pinned versions were checked against each project's support matrix (2026-10-19): KubeVirt 1.9
supports Kubernetes 1.34–1.36, Calico 3.33 is tested on 1.35–1.37, Rook 1.20.8 supports
1.31–1.37 with Ceph 19/20, and Kubernetes 1.36 needs containerd 2.x.

### Source branches

| Folder | Branch | Based on |
|---|---|---|
| `apps/kubevirt` | `vmm/v1.9.0` | tag `v1.9.0` |
| `apps/rook` | `vmm/v1.20.8` | tag `v1.20.8` |
| `apps/VM-Manager` | `vmm/offline-iso` | offline installer, local PostgreSQL storage |

Make your changes on these branches.

### KubeVirt

```bash
./m.sh kubevirt
```

| Output | Contents |
|---|---|
| `docker/images/kubevirt/*.tar` | `virt-operator`, `virt-api`, `virt-controller`, `virt-handler`, `virt-launcher`, `virt-exportserver`, `virt-exportproxy`, `virt-synchronization-controller` |
| `docker/images/kubevirt/images.txt` | Image names contained in the tarballs |
| `manifests/kubevirt/` | `kubevirt-operator.yaml`, `kubevirt-cr.yaml`, ... |

The first build takes a long time and downloads several GB; later builds reuse a cache and take
a few minutes. Options (`./m.sh kubevirt --help` lists all):

| Option | Purpose |
|---|---|
| `--tag TAG` | Image tag (default: `git describe` of `apps/kubevirt`, e.g. `v1.9.0`) |
| `--prefix PREFIX` | Image registry/prefix used in the tarballs and manifests (default: `kubevirt`) |
| `--images "A B"` | Build only some images |
| `--generate` | Also run the full code generation (needed after API type changes) |

`./m.sh kubevirt clean` deletes the build cache; the next build starts from scratch.

#### Adding or modifying Go code

1. **Write your code** in `apps/kubevirt`, under `pkg/`, `cmd/`, `tools/` or `tests/`:
   - Change an existing file: just edit it.
   - Add a file to an existing package: create it in that folder, e.g. `pkg/virt-handler/myfeature.go`.
   - Add a new package: create a new folder with your `.go` files, e.g. `pkg/myfeature/myfeature.go`, and import it where it is used.

2. **Tell git about new files.** Only brand-new files need this; edited files are picked up automatically. No commit is needed.

   ```bash
   cd apps/kubevirt
   git add pkg/myfeature/
   cd ../..
   ```

3. **Build.** When you deploy builds to a running cluster by hand, use a new tag for every
   build (`dev-1`, `dev-2`, ...), so the cluster does not keep running an older image with the
   same tag:

   ```bash
   ./m.sh kubevirt --tag dev-1
   ```

   The build updates (or creates) the `BUILD.bazel` files for your changes and copies them back into `apps/kubevirt`.

4. **Commit your change together with the updated `BUILD.bazel` files:**

   ```bash
   cd apps/kubevirt
   git status
   git add -A
   git commit -m "Add my feature"
   ```

5. **Rebuild the ISO** (`./m.sh bundle && ./m.sh iso`), or deploy by hand (see [Deploying KubeVirt by hand](#deploying-kubevirt-by-hand)).

Special cases:

| You changed... | Do this |
|---|---|
| API types in `staging/src/kubevirt.io/api/` | `./m.sh kubevirt --generate` |
| Added a new third-party Go library | `go get` it and run `go mod vendor` before building |
| Build fails with "undefined" or "missing dependency" | Check that the new files were `git add`-ed |

### Rook

```bash
./m.sh rook
```

Builds the Rook operator image (`docker.io/rook/ceph:<tag>`) from `apps/rook` with Rook's own
Makefile, inside a pinned Go container. Outputs `docker/images/rook/rook-ceph.tar` and
`manifests/rook/` (`crds`, `common`, `csi-operator`, `operator`, set to the built image). The
images Rook deploys but doesn't build (Ceph, the CSI drivers) come from `./m.sh deps`.

### VM Manager

```bash
./m.sh vm-manager
```

Builds `vm-manager:<VM_MANAGER_VERSION>` with the project's Dockerfile (React console + Spring
Boot). Outputs `docker/images/vm-manager/vm-manager.tar` and `manifests/vm-manager/` (its
`deploy/` folder and `installer/install.sh`).

### Dependencies

```bash
./m.sh deps
```

Downloads everything not built from `apps/` into `cache/deps/`: the Ubuntu and Kubernetes
`.deb` packages with all their dependencies (as a local apt repository), containerd and runc,
the Calico, Multus, metrics-server, CDI and snapshot-controller manifests, and 34 container
images (Kubernetes, Calico, CDI, Ceph and its CSI drivers, PostgreSQL, the host agent's JDK).
Two upstream manifests are corrected to the pinned versions: Multus' release manifest uses the
moving `snapshot-thick` tag, and the snapshot controller's an older image.

### Bundle and ISO

```bash
./m.sh bundle    # collect everything into bundle/ and check it
./m.sh iso       # output/vm-manager-<version>-<bundle id>.iso (~9 GB)
```

`./m.sh bundle` refuses to produce a bundle that would fail offline: it reads the image names
from inside every tarball and checks that each image any manifest uses is among them, that each
build matches `versions.env`, and that no shell script has Windows line endings.

`./m.sh iso` downloads the Ubuntu Server ISO once into `cache/ubuntu/` (SHA256 checked; use your
own copy with `UBUNTU_ISO=/path/to.iso`) and adds the bundle, the automatic install and a boot
menu. `bundle/versions.txt` (and `/opt/vm-manager/versions.txt` on a server) records exactly
which source commits and versions went in.

### Installing a server from the ISO

Write the ISO to a USB stick (Rufus in DD mode, balenaEtcher, or `dd`) and boot the server.
The server needs Intel VT-x/AMD-V turned on in the BIOS and should have 16 GB of memory or more.

1. Pick a boot menu entry:
   - **Install VM Manager - first server (new cluster)**
   - **Install VM Manager - join an existing cluster**
2. The Ubuntu installer asks only for the **network** (use a fixed IP; it must have a gateway),
   the **disk**, and the **hostname and admin user** (every server needs its own hostname).
3. After the reboot, the first boot sets everything up (`vmm-firstboot.service`):
   - **First server:** installs Kubernetes, KubeVirt, CDI, Rook-Ceph, Multus, PostgreSQL and
     VM Manager from `/opt/vm-manager`. Progress: `sudo journalctl -fu vmm-firstboot`. When it's
     done the login screen shows `http://<ip>:30080`; sign in as `root` with the password in
     `/root/vm-manager-initial-password`. If it fails (e.g. network), fix the cause and run
     `sudo vmm-install`, or reboot: it continues where it stopped.
   - **Join:** in the console of the existing cluster open **Servers › Add server**, then on the
     new server run `sudo vmm-join <console-url> <join-code>`.

PostgreSQL keeps its data on the first server's OS disk (`/var/lib/vm-manager/postgres`), so the
console works before Ceph has any disks; Ceph disks are chosen in the console's setup wizard.

### Testing the ISO

```bash
./m.sh iso --unattended    # asks nothing: DHCP, whole first disk, user vmm / password vmm
./m.sh test-iso            # installs it in a QEMU VM without internet, waits for VM Manager
```

The test VM has no internet access at all (QEMU user networking with `restrict=on`). It needs
`/dev/kvm` in Docker (Docker Desktop with `nestedVirtualization=true` in `.wslconfig`). While it
runs, VM Manager is at http://localhost:30080 and SSH at `ssh -p 2222 vmm@localhost`. Stop it
with `docker rm -f vm-manager-iso-test`. Never put an `--unattended` ISO on real servers: it
erases the first disk and has a fixed password.

### Deploying KubeVirt by hand

Without the ISO, on an existing cluster: all 8 KubeVirt images are needed on every node
(`virt-handler` runs on every node, `virt-launcher` wherever a VM runs).

**Option A: import on every node (no registry).** Copy `docker/images/kubevirt/*.tar` to each
node and run:

```bash
for f in *.tar; do sudo ctr -n k8s.io images import "$f"; done
```

**Option B: push to a registry the cluster pulls from.** Build with
`--prefix <registry>/kubevirt` so the tarballs and manifests use that name, then on any machine
with Docker:

```bash
for f in *.tar; do docker load -i "$f"; done
for img in $(cat images.txt); do docker push "$img"; done
```

Then apply the manifests from `manifests/kubevirt/`, in this order:

```bash
kubectl apply -f kubevirt-operator.yaml   # namespace, CRD, RBAC, virt-operator
kubectl apply -f kubevirt-cr.yaml         # tells the operator to install KubeVirt
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=10m
```

The operator deploys the other components itself and refers to their images by the same prefix
and tag, so they must all come from the same build. The other generated files are not needed
for a normal install:

| File | Apply it? |
|---|---|
| `kubevirt-network-policies.yaml` | Only if the cluster denies pod traffic by default (default-deny NetworkPolicy); it opens the ports KubeVirt needs |
| `demo-content.yaml` | No, example VM preset |
| `conformance.yaml` | No, config for KubeVirt's conformance test suite |
| `olm/` | No, alternative install through OLM (OpenShift); use instead of the two files above, not in addition |

### Notes for the build machine

- Docker Desktop keeps its data (build caches, pulled images) in one disk image on C:. Move it to
  a bigger drive under Settings › Resources › Advanced › Disk image location if C: is small.
- Build caches: `./m.sh kubevirt clean` and `./m.sh rook clean` remove them.
- Logs of long runs are easiest to keep with `./m.sh all 2>&1 | tee logs/all.log`.
