#!/bin/bash
# K3s Cluster Setup with QEMU VMs

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# script configuration
export BASE_DIR=${SCRIPTDIR:-$(pwd)}

# vm configuration
export BASE_IMAGE=${BASE_IMAGE:-"noble-server-cloudimg-amd64.img"}
export CONTROL_IP=${CONTROL_IP:-"172.16.0.10"}
export WORKER1_IP=${WORKER1_IP:-"172.16.0.11"}
export NETWORK_CIDR=${NETWORK_CIDR:-"172.16.0.0/24"}
export BRIDGE_NAME=${BRIDGE_NAME:-"br-kubernetes"}

# k3s configuration
export K8S_POD_CIDR=${K8S_POD_CIDR:-"192.168.0.0/16"}

# ── Create SSH keys
create_ssh_keys() {
    echo "[1/9] Creating SSH keys"

    if [ ! -f $HOME/.ssh/id_ed25519_qemu ]; then
        ssh-keygen -t ed25519 -C "testuser@$HOSTNAME" -f "$HOME/.ssh/id_ed25519_qemu" -q -N ""
    fi
    export SSH_PUBLIC_KEY=$(<$HOME/.ssh/id_ed25519_qemu.pub)
}

# ── Create Directory Structure
create_dir_structure() {
    echo "[2/9] Creating directory structure"

    mkdir -p "$BASE_DIR"/{control,worker1}
    cd "$BASE_DIR"
}

# ── Download Base Cloud Image
download_cloud_image() {
    if [ ! -f "$BASE_IMAGE" ]; then
        echo "[3/9] Downloading Base cloud image..."
        wget https://cloud-images.ubuntu.com/noble/current/$BASE_IMAGE -O "$BASE_IMAGE"
    else
        echo "[3/9] Base cloud image already exists"
    fi
}

# ── Create Backing Store (Overlay Image)
create_backing_store() {
    echo "[4/9] Creating VM disk images..."

    qemu-img create -f qcow2 -F qcow2 -b "../$BASE_IMAGE" control/overlay.qcow2 20G
    qemu-img create -f qcow2 -F qcow2 -b "../$BASE_IMAGE" worker1/overlay.qcow2 20G
}

# ── Create Cloud-Init configuration for Control Plane
create_init_control() {
    echo "[5/9] Creating cloud-init configuration for control plane..."

    # Create meta-data file
    cat > control/meta-data <<EOF
instance-id: control
local-hostname: control
EOF

    # Create network-config (for static IP)
    cat > control/network-config <<EOF
network:
  version: 2
  ethernets:
    ens2:
      match:
        macaddress: '52:54:00:12:34:10'
      dhcp4: no
      dhcp6: no
      addresses:
        - ${CONTROL_IP}/24
      routes:
      - to: 0.0.0.0/0
        via: 172.16.0.1
      nameservers:
        addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF

    cat > control/user-data <<EOF
#cloud-config

apt:
  sources:
    docker.list:
      source: deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

groups:
  - docker

users:
  - name: testuser
    groups:
      - sudo
      - docker
    lock_passwd: false
    plain_text_passwd: Csit1234
    shell: /bin/bash
    ssh_authorized_keys:
    - $SSH_PUBLIC_KEY
    sudo: ALL=(ALL) NOPASSWD:ALL

locale: en_US.UTF-8
timezone: UTC

package_update: true
package_upgrade: false
package_reboot_if_required: false

packages:
  - apt-transport-https
  - ca-certificates
  - containerd.io
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - gnupg2
  - jq
  - software-properties-common

write_files:
  - path: /etc/sysctl.d/kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-ip6tables = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
  - path: /etc/modules-load.d/containerd.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/containerd/config.toml
    content: |
      version = 2
      [plugins]
      [plugins."io.containerd.grpc.v1.cri"]
      [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
  - path: /etc/calico-vpp-multinet.yaml
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: calico-vpp-dataplane
      ---
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: calico-vpp-node-sa
        namespace: calico-vpp-dataplane
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRole
      metadata:
        name: calico-vpp-node-role
      rules:
      - apiGroups:
        - ""
        resources:
        - pods
        - nodes
        - namespaces
        verbs:
        - get
      - apiGroups:
        - ""
        resources:
        - endpoints
        - services
        verbs:
        - watch
        - list
        - get
        - create
        - update
      - apiGroups:
        - k8s.cni.cncf.io
        resources:
        - network-attachment-definitions
        verbs:
        - watch
        - get
        - list
      - apiGroups:
        - ""
        resources:
        - configmaps
        verbs:
        - get
      - apiGroups:
        - ""
        resources:
        - nodes/status
        verbs:
        - patch
        - update
      - apiGroups:
        - networking.k8s.io
        resources:
        - networkpolicies
        verbs:
        - watch
        - list
      - apiGroups:
        - ""
        resources:
        - pods
        - namespaces
        - serviceaccounts
        verbs:
        - list
        - watch
      - apiGroups:
        - ""
        resources:
        - pods/status
        verbs:
        - patch
      - apiGroups:
        - projectcalico.org
        resources:
        - networks
        verbs:
        - list
        - get
        - watch
      - apiGroups:
        - crd.projectcalico.org
        resources:
        - globalfelixconfigs
        - felixconfigurations
        - bgppeers
        - bgpfilters
        - globalbgpconfigs
        - bgpconfigurations
        - ippools
        - ipamblocks
        - globalnetworkpolicies
        - globalnetworksets
        - networkpolicies
        - networksets
        - clusterinformations
        - hostendpoints
        - blockaffinities
        verbs:
        - get
        - list
        - watch
      - apiGroups:
        - ""
        resources:
        - nodes
        verbs:
        - get
        - list
        - watch
      - apiGroups:
        - crd.projectcalico.org
        resources:
        - blockaffinities
        - ipamblocks
        - ipamhandles
        verbs:
        - get
        - list
        - create
        - update
        - delete
      - apiGroups:
        - crd.projectcalico.org
        resources:
        - ipamconfigs
        verbs:
        - get
      - apiGroups:
        - crd.projectcalico.org
        resources:
        - blockaffinities
        verbs:
        - watch
      - apiGroups:
        - discovery.k8s.io
        resources:
        - endpointslices
        verbs:
        - watch
        - list
        - get
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: calico-vpp-node
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: calico-vpp-node-role
      subjects:
      - kind: ServiceAccount
        name: calico-vpp-node-sa
        namespace: calico-vpp-dataplane
      ---
      apiVersion: v1
      data:
        CALICOVPP_CONFIG_TEMPLATE: |-
          unix {
            nodaemon
            full-coredump
            cli-listen /var/run/vpp/cli.sock
            pidfile /run/vpp/vpp.pid
            exec /etc/vpp/startup.exec
          }
          api-trace { on }
          cpu {
              main-core 1
              corelist-workers 2,3,4,5,6,7,8,9
          }
          socksvr {
              socket-name /var/run/vpp/vpp-api.sock
          }
          plugins {
              plugin default { enable }
              plugin dpdk_plugin.so { disable }
              plugin calico_plugin.so { enable }
              plugin ping_plugin.so { disable }
              plugin dispatch_trace_plugin.so { enable }
          }
          buffers {
            buffers-per-numa 131072
          }
        CALICOVPP_FEATURE_GATES: |-
          {
            "memifEnabled": true,
            "vclEnabled": true,
            "multinetEnabled": true
          }
        CALICOVPP_INITIAL_CONFIG: |-
          {
            "vppStartupSleepSeconds": 1,
            "corePattern": "/var/lib/vpp/vppcore.%e.%p"
          }
        CALICOVPP_INTERFACES: |-
          {
            "maxPodIfSpec": {
              "rx": 10, "tx": 10, "rxqsz": 1024, "txqsz": 1024
            },
            "defaultPodIfSpec": {
              "rx": 1, "tx":1, "isl3": true
            },
            "vppHostTapSpec": {
              "rx": 1, "tx":1, "rxqsz": 1024, "txqsz": 1024, "isl3": false
            },
            "uplinkInterfaces": [
              {
                "interfaceName": "ens5",
                "vppDriver": "avf",
                "rx": 8,
                "rxMode": "polling"
              },
              {
                "interfaceName": "ens6",
                "vppDriver": "avf",
                "rx": 8,
                "rxMode": "polling"
              }
            ]
          }
        SERVICE_PREFIX: 10.96.0.0/12
      kind: ConfigMap
      metadata:
        name: calico-vpp-config
        namespace: calico-vpp-dataplane
      ---
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        labels:
          k8s-app: calico-vpp-node
        name: multinet-monitor-deployment
        namespace: calico-vpp-dataplane
      spec:
        replicas: 1
        selector:
          matchLabels:
            k8s-app: calico-vpp-node
        template:
          metadata:
            labels:
              k8s-app: calico-vpp-node
          spec:
            containers:
            - image: docker.io/calicovpp/multinet-monitor:latest
              imagePullPolicy: IfNotPresent
              name: multinet-monitor
              resources:
                requests:
                  cpu: 250m
            serviceAccountName: calico-vpp-node-sa
      ---
      apiVersion: apps/v1
      kind: DaemonSet
      metadata:
        labels:
          k8s-app: calico-vpp-node
        name: calico-vpp-node
        namespace: calico-vpp-dataplane
      spec:
        selector:
          matchLabels:
            k8s-app: calico-vpp-node
        template:
          metadata:
            labels:
              k8s-app: calico-vpp-node
          spec:
            containers:
            - env:
              - name: DATASTORE_TYPE
                value: kubernetes
              - name: WAIT_FOR_DATASTORE
                value: "true"
              - name: NODENAME
                valueFrom:
                  fieldRef:
                    fieldPath: spec.nodeName
              - name: NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
              envFrom:
              - configMapRef:
                  name: calico-vpp-config
              image: docker.io/calicovpp/agent:latest
              imagePullPolicy: IfNotPresent
              name: agent
              resources:
                requests:
                  cpu: 250m
              securityContext:
                privileged: true
              volumeMounts:
              - mountPath: /var/run/calico
                name: var-run-calico
                readOnly: false
              - mountPath: /var/lib/calico/felix-plugins
                name: felix-plugins
                readOnly: false
              - mountPath: /var/run/vpp
                name: vpp-rundir
              - mountPath: /run/netns/
                mountPropagation: Bidirectional
                name: netns
            - env:
              - name: DATASTORE_TYPE
                value: kubernetes
              - name: WAIT_FOR_DATASTORE
                value: "true"
              - name: NODENAME
                valueFrom:
                  fieldRef:
                    fieldPath: spec.nodeName
              envFrom:
              - configMapRef:
                  name: calico-vpp-config
              image: docker.io/calicovpp/vpp:latest
              imagePullPolicy: IfNotPresent
              name: vpp
              resources:
                limits:
                  hugepages-2Mi: 2048Mi
                requests:
                  cpu: 500m
                  memory: 2048Mi
              securityContext:
                privileged: true
              volumeMounts:
              - mountPath: /lib/firmware
                name: lib-firmware
              - mountPath: /var/run/vpp
                name: vpp-rundir
              - mountPath: /var/lib/vpp
                name: vpp-data
              - mountPath: /etc/vpp
                name: vpp-config
              - mountPath: /dev
                name: devices
              - mountPath: /sys
                name: hostsys
              - mountPath: /run/netns/
                mountPropagation: Bidirectional
                name: netns
              - mountPath: /host
                name: host-root
            hostNetwork: true
            hostPID: true
            initContainers:
            - command:
              - /entrypoint
              image: docker.io/calicovpp/install-whereabouts:latest
              name: install-whereabouts
              volumeMounts:
              - mountPath: /host/opt/cni/bin
                name: cni-bin-dir
            nodeSelector:
              kubernetes.io/os: linux
            priorityClassName: system-node-critical
            serviceAccountName: calico-vpp-node-sa
            terminationGracePeriodSeconds: 10
            tolerations:
            - effect: NoSchedule
              operator: Exists
            - key: CriticalAddonsOnly
              operator: Exists
            - effect: NoExecute
              operator: Exists
            volumes:
            - hostPath:
                path: /opt/cni/bin
              name: cni-bin-dir
            - hostPath:
                path: /lib/firmware
              name: lib-firmware
            - hostPath:
                path: /var/run/vpp
              name: vpp-rundir
            - hostPath:
                path: /var/lib/vpp
                type: DirectoryOrCreate
              name: vpp-data
            - hostPath:
                path: /etc/vpp
              name: vpp-config
            - hostPath:
                path: /dev
              name: devices
            - hostPath:
                path: /sys
              name: hostsys
            - hostPath:
                path: /var/run/calico
              name: var-run-calico
            - hostPath:
                path: /run/netns
              name: netns
            - hostPath:
                path: /var/lib/calico/felix-plugins
              name: felix-plugins
            - hostPath:
                path: /
              name: host-root
        updateStrategy:
          rollingUpdate:
            maxUnavailable: 1

runcmd:
  - systemctl enable containerd
  - systemctl daemon-reload
  - modprobe br_netfilter
  - modprobe overlay
  - swapoff -a
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-backend=none --node-ip ${CONTROL_IP} --cluster-cidr ${K8S_POD_CIDR} --disable-network-policy --write-kubeconfig-mode 644 --token 12345" sh -s -
  - kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/operator-crds.yaml
  - kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml
  - kubectl create -f /etc/calico-vpp-multinet.yaml
  - kubectl get nodes

final_message: |
  K3s Control Plane Ready!
  Node IP: ${CONTROL_IP}
  Access: ssh testuser@${CONTROL_IP}
EOF
}

# ── Create Cloud-Init Files for Worker
create_init_worker1() {
    echo "[6/9] Creating cloud-init configuration for worker..."

    # Create meta-data file
    cat > worker1/meta-data <<EOF
instance-id: worker1
local-hostname: worker1
EOF

    # Create network-config (optional - for static IP)
    cat > worker1/network-config <<EOF
network:
  version: 2
  ethernets:
    ens2:
      match:
        macaddress: '52:54:00:12:34:11'
      dhcp4: no
      dhcp6: no
      addresses:
        - ${WORKER1_IP}/24
      routes:
      - to: 0.0.0.0/0
        via: 172.16.0.1
      nameservers:
        addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF

    cat > worker1/user-data <<EOF
#cloud-config

apt:
  sources:
    docker.list:
      source: deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

groups:
  - docker

users:
  - name: testuser
    groups:
      - sudo
      - docker
    lock_passwd: false
    plain_text_passwd: Csit1234
    shell: /bin/bash
    ssh_authorized_keys:
    - $SSH_PUBLIC_KEY
    sudo: ALL=(ALL) NOPASSWD:ALL

locale: en_US.UTF-8
timezone: UTC

package_update: true
package_upgrade: false
package_reboot_if_required: false

packages:
  - apt-transport-https
  - build-essential
  - ca-certificates
  - containerd.io
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - gnupg2
  - jq
  - libnuma-dev
  - software-properties-common

write_files:
  - path: /etc/sysctl.d/kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-ip6tables = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
  - path: /etc/modules-load.d/containerd.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/containerd/config.toml
    content: |
      version = 2
      [plugins]
      [plugins."io.containerd.grpc.v1.cri"]
      [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true

runcmd:
  - systemctl enable containerd
  - systemctl daemon-reload
  - modprobe br_netfilter
  - modprobe overlay
  - echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  - modprobe vfio enable_unsafe_noiommu_mode=1
  - modprobe vfio-pci
  - swapoff -a
  - echo 4096 | sudo tee /proc/sys/vm/nr_hugepages
  - ip a add 192.168.1.2/24 dev ens5
  - ip a add 192.168.2.2/24 dev ens6
  - ip n add 192.168.1.1 lladdr 40:a6:b7:ca:2a:70 dev ens5
  - ip n add 192.168.2.1 lladdr 40:a6:b7:ca:2a:74 dev ens6
  - ip l set dev ens5 up
  - ip l set dev ens6 up
  - ip route add 10.0.0.0/8 via 192.168.1.1
  - ip route add 20.0.0.0/8 via 192.168.2.1
  - curl -L https://github.com/intel/ethernet-linux-iavf/releases/download/v4.13.20/iavf-4.13.20.tar.gz -o /opt/iavf-4.13.20.tar.gz
  - cd /opt/ && tar xzf iavf-4.13.20.tar.gz
  - cd /opt/iavf-4.13.20/src && make install
  - timeout 300 bash -c 'until ping -c 1 ${CONTROL_IP} >/dev/null 2>&1; do sleep 5; done'
  - curl -sfL https://get.k3s.io | K3S_URL=https://${CONTROL_IP}:6443 K3S_TOKEN=12345 sh -s -

final_message: |
  K3s Worker1 Ready!
  Node IP: ${WORKER1_IP}
  Access: ssh testuser@${WORKER1_IP}
EOF

# ── Create Cloud-Init ISOs
create_init_worker1() {
    echo "[7/9] Create cloud-init ISOs..."

    # Control plane ISO
    cloud-localds control/cloud-init.iso control/user-data control/meta-data --network-config control/network-config
    # Worker ISO
    cloud-localds worker1/cloud-init.iso worker1/user-data worker1/meta-data --network-config worker1/network-config
}

# ── Create Network Bridge Script
create_init_network() {
    echo "[8/9] Creating network setup script..."

    cat > setup-network.sh <<NETSCRIPT
#!/bin/bash
# Setup network bridge for k3s cluster VMs

# Check if bridge already exists
if ip link show "$BRIDGE_NAME" &> /dev/null; then
    echo "Bridge $BRIDGE_NAME already exists"
    exit 0
fi

echo "Creating bridge network $BRIDGE_NAME..."

# Create bridge
sudo ip link add name "$BRIDGE_NAME" type bridge
sudo ip addr add 172.16.0.1/24 dev "$BRIDGE_NAME"
sudo ip link set "$BRIDGE_NAME" up

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# Setup NAT for internet access
sudo iptables -t nat -A POSTROUTING -s $NETWORK_CIDR ! -d $NETWORK_CIDR -j MASQUERADE
sudo iptables -A FORWARD -i "$BRIDGE_NAME" -o "$BRIDGE_NAME" -j ACCEPT

echo "Bridge network created successfully!"
echo "Bridge IP: 172.16.0.1"
echo "Network: $NETWORK_CIDR"

sudo mkdir -p /etc/qemu/
echo "allow br-kubernetes" | sudo tee /etc/qemu/bridge.conf
NETSCRIPT

    cat > setup-pci.sh <<'PCISCRIPT'
#!/bin/bash
# Setup PCI interfaces

echo 1 | sudo tee /sys/class/net/ens1280np0/device/sriov_numvfs
echo 1 | sudo tee /sys/class/net/ens1281np0/device/sriov_numvfs

sudo python3 /opt/dpdk/usertools/dpdk-devbind.py -b vfio-pci 0000:b8:01.0 0000:ba:01.0
PCISCRIPT
}

# ── Create VM Startup Scripts
create_init_vms() {
    echo "[8/9] Creating VM startup scripts..."

    cat > stop-all.sh <<'STOPSCRIPT'
#!/bin/bash
# Stop all VMs

cd "$(dirname "$0")"

if [ -f control.pid ]; then
    echo "Stopping control plane..."
    ssh-keygen -f '/home/testuser/.ssh/known_hosts' -R '172.16.0.10'
    sudo kill $(sudo cat control.pid) 2>/dev/null
    sudo rm control/overlay.qcow2
fi

if [ -f worker1.pid ]; then
    echo "Stopping worker1..."
    ssh-keygen -f '/home/testuser/.ssh/known_hosts' -R '172.16.0.11'
    sudo kill $(sudo cat worker1.pid) 2>/dev/null
    sudo rm worker1/overlay.qcow2
fi

echo "All VMs stopped"
STOPSCRIPT

    # Headless versions
    cat > start-control.sh <<'CONTROL'
#!/bin/bash
# Start k3s control plane VM (headless)

sudo /usr/bin/qemu-system-x86_64 \
    -daemonize \
    -nodefaults \
    -name control,debug-threads=on \
    -no-user-config \
    -nographic \
    -enable-kvm \
    -netdev bridge,id=net0,br=br-kubernetes \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:10 \
    -pidfile control.pid \
    -cpu host,migratable=on \
    -machine pc,accel=kvm,usb=off,mem-merge=off,hpet=off \
    -smp 8,sockets=8,dies=1,cores=1,threads=1 \
    -object memory-backend-file,id=mem,size=8192M,mem-path=/dev/hugepages,share=on \
    -m 8192M \
    -overcommit mem-lock=off \
    -numa node,memdev=mem \
    -drive file=control/overlay.qcow2,if=virtio,format=qcow2,cache=writeback \
    -drive file=control/cloud-init.iso,index=1,media=cdrom \
    -serial file:control-serial.log
CONTROL

    cat > start-worker1.sh <<'WORKER'
#!/bin/bash
# Start k3s worker VM (headless)

sudo /usr/bin/qemu-system-x86_64 \
    -daemonize \
    -nodefaults \
    -name worker1,debug-threads=on \
    -no-user-config \
    -nographic \
    -enable-kvm \
    -netdev bridge,id=net0,br=br-kubernetes \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:11 \
    -device vfio-pci,host=0000:b8:00.0,bus=pci.0,addr=0x5 \
    -device vfio-pci,host=0000:ba:00.0,bus=pci.0,addr=0x6 \
    -pidfile worker1.pid \
    -cpu host,migratable=on \
    -machine pc,accel=kvm,usb=off,mem-merge=off,hpet=off \
    -smp 10,sockets=10,dies=1,cores=1,threads=1 \
    -object memory-backend-file,id=mem,size=16384M,mem-path=/dev/hugepages,share=on \
    -m 16384M \
    -overcommit mem-lock=off \
    -numa node,memdev=mem \
    -drive file=worker1/overlay.qcow2,if=virtio,format=qcow2,cache=writeback \
    -drive file=worker1/cloud-init.iso,index=1,media=cdrom \
    -serial file:worker1-serial.log
WORKER
}


create_ssh_keys
create_dir_structure
download_cloud_image
create_backing_store
create_init_control
create_init_worker1
create_init_network
create_init_vms

chmod +x *.sh

