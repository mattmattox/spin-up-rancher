#!/bin/bash

# Function to install autok3s if not already installed
install_autok3s() {
  if ! command -v autok3s &> /dev/null; then
    echo "autok3s not found. Installing autok3s..."
    curl -sS https://rancher-mirror.rancher.cn/autok3s/install.sh | sh
    echo "autok3s installed successfully."
  else
    echo "autok3s is already installed."
  fi
}

# Function to install KVM, QEMU, and required tools if not installed
install_kvm_qemu() {
  # Check if KVM, QEMU, and libvirt are installed
  if ! dpkg -l | grep -qw qemu-kvm || ! dpkg -l | grep -qw libvirt-daemon-system || ! dpkg -l | grep -qw virtinst; then
    echo "KVM, QEMU, or required packages not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst
    sudo systemctl enable --now libvirtd
    sudo usermod -aG libvirt $USER
    echo "KVM and QEMU installed successfully. Please reboot or log out and back in for group changes to take effect."
  else
    echo "KVM and QEMU are already installed."
  fi
}

# Function to download and prepare the cloud image
download_cloud_image() {
  image_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  image_path="/var/lib/libvirt/images/ubuntu-noble-cloudimg.qcow2"

  if [ ! -f "$image_path" ]; then
    echo "Downloading cloud image..."
    sudo wget -O "$image_path" "$image_url"
  else
    echo "Cloud image already downloaded."
  fi
}

# Function to resize the cloud image
resize_cloud_image() {
  vm_name=$1
  vm_disk=$2
  base_image="/var/lib/libvirt/images/ubuntu-noble-cloudimg.qcow2"
  vm_image="/var/lib/libvirt/images/${vm_name}.qcow2"

  echo "Creating VM disk from cloud image for $vm_name..."
  sudo cp "$base_image" "$vm_image"
  sudo qemu-img resize "$vm_image" "${vm_disk}G"
}

# Function to create cloud-init ISO for VM with qemu-guest-agent
create_cloud_init_iso() {
  vm_name=$1
  cat > /tmp/meta-data <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF

  cat > /tmp/user-data <<EOF
#cloud-config
users:
  - default
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $ssh_key

# Install qemu-guest-agent to report IP addresses
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent

# Ensure qemu-guest-agent is enabled and running
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  # Suppressing the output of genisoimage
  genisoimage -output /tmp/$vm_name-cloud-init.iso -volid cidata -joliet -rock /tmp/user-data /tmp/meta-data > /dev/null 2>&1
}

# Function to check if VM exists and delete it if necessary
delete_vm_if_exists() {
  vm_name=$1
  if virsh list --all | grep -q "$vm_name"; then
    echo "VM $vm_name already exists. Deleting it..."
    sudo virsh destroy "$vm_name" || echo "VM $vm_name was not running."
    sudo virsh undefine "$vm_name" --remove-all-storage
    sudo rm -f /tmp/$vm_name-cloud-init.iso
    sudo rm -f /var/lib/libvirt/images/${vm_name}.qcow2
  fi
}

# Function to create a new NAT network if it doesn't exist
create_nat_network() {
  network_name="private-nat"
  network_xml="/tmp/${network_name}.xml"

  if virsh net-info "$network_name" > /dev/null 2>&1; then
    echo "Network $network_name already exists."
  else
    echo "Creating new NAT network: $network_name..."
    cat > $network_xml <<EOF
<network>
  <name>$network_name</name>
  <forward mode='nat'/>
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.100' end='192.168.100.200'/>
    </dhcp>
  </ip>
</network>
EOF
    virsh net-define $network_xml
    virsh net-start $network_name
    virsh net-autostart $network_name
    echo "NAT network $network_name created and started."
  fi
}

# Function to create VMs using virt-install with cloud image
create_vm() {
  vm_name=$1
  vm_ram=$2
  vm_cpu=$3
  vm_disk=$4

  # Delete VM if it already exists
  delete_vm_if_exists $vm_name

  # Download the cloud image if not available
  download_cloud_image

  # Resize the cloud image for this VM
  resize_cloud_image $vm_name $vm_disk

  # Create the cloud-init ISO for the VM
  create_cloud_init_iso $vm_name

  echo "Creating VM: $vm_name with $vm_ram MB RAM, $vm_cpu CPUs, $vm_disk GB disk..."

  virt-install \
    --name "$vm_name" \
    --ram "$vm_ram" \
    --vcpus "$vm_cpu" \
    --disk path=/var/lib/libvirt/images/"$vm_name".qcow2,format=qcow2 \
    --disk path=/tmp/$vm_name-cloud-init.iso,device=cdrom \
    --network bridge=virbr1,model=virtio \
    --os-variant ubuntu24.04 \
    --graphics spice \
    --console pty,target_type=serial \
    --noautoconsole \
    --import

  if [ $? -eq 0 ]; then
    echo "VM $vm_name created successfully."
  else
    echo "Failed to create VM $vm_name."
  fi
}

# Function to display the IP addresses of the VMs using DHCP leases
show_vm_ips() {
  echo "Displaying IP addresses of VMs:"
  for vm_name in "$@"; do
    ip=$(sudo virsh net-dhcp-leases private-nat | grep "$vm_name" | awk '{print $5}' | cut -d '/' -f 1)
    if [ -n "$ip" ]; then
      echo "VM: $vm_name has IP: $ip"
    else
      echo "No IP found for VM: $vm_name"
    fi
  done
}
# Function to wait for namespace creation
wait_for_namespace() {
  namespace=$1
  echo "Waiting for namespace $namespace to be created..."
  while ! kubectl get namespace $namespace > /dev/null 2>&1; do
    echo "Namespace $namespace not found, waiting..."
    sleep 2
  done
  echo "Namespace $namespace is now available."
}

# Function to wait for Helm install Pods to complete
wait_for_helm_pod() {
  pod_name=$1
  namespace=$2
  echo "Waiting for Helm install Pod $pod_name to be created..."

  # Wait until the pod exists
  while ! kubectl get pod -n $namespace -l job-name=$pod_name > /dev/null 2>&1; do
    echo "Helm install Pod $pod_name not created yet, waiting..."
    sleep 5
  done

  echo "Helm install Pod $pod_name found. Waiting for it to complete..."

  # Wait for the pod to succeed
  while true; do
    pod_status=$(kubectl get pod -n $namespace -l job-name=$pod_name -o jsonpath='{.items[0].status.phase}')

    if [ "$pod_status" == "Succeeded" ]; then
      echo "Helm install Pod $pod_name completed successfully."
      break
    elif [ "$pod_status" == "Failed" ]; then
      echo "Helm install Pod $pod_name failed."
      exit 1
    else
      echo "Helm install Pod $pod_name is still running (status: $pod_status), waiting..."
    fi
    sleep 5
  done
}

# Get the version from the command-line argument, e.g., v2.9.2
version=$1

# Ensure the version is provided
if [ -z "$version" ]; then
  echo "Usage: $0 <rancher-version>"
  exit 1
fi

# Convert the version to a name-friendly format (replace dots with dashes)
name_version=$(echo "$version" | sed 's/\./-/g')

# Install autok3s if not present
install_autok3s

# Clean up any previous cluster or Docker containers
echo "Cleaning up any previous clusters or containers for rancher-$name_version..."

# Delete existing k3d cluster if it exists
autok3s delete --provider k3d --name rancher-$name_version
autok3s delete --provider k3d --name rancher-$name_version --force

# Remove any related Docker containers if they exist
docker ps -a | grep k3d-rancher-$name_version | awk '{print $1}' | xargs docker rm -f || echo "No related Docker containers to remove."

# SSH public key to add to the VMs
ssh_key=$(cat ~/.ssh/id_rsa.pub)

# Define VM configurations (you can add or modify these as needed)
vm_configs=(
  "rancher-vm1 4096 2 20"  # VM name, RAM (MB), CPU count, Disk size (GB)
  "rancher-vm2 4096 2 20"
  "rancher-vm3 4096 2 20"
)

# Install KVM and QEMU if not present
install_kvm_qemu

# Create NAT network
create_nat_network

# Create an array to store VM names for later use
vm_names=()

# Loop through the VM configurations and create each VM
for config in "${vm_configs[@]}"; do
  vm_name=$(echo $config | awk '{print $1}')
  vm_ram=$(echo $config | awk '{print $2}')
  vm_cpu=$(echo $config | awk '{print $3}')
  vm_disk=$(echo $config | awk '{print $4}')
  create_vm "$vm_name" "$vm_ram" "$vm_cpu" "$vm_disk"
  vm_names+=("$vm_name")
done

# Create the new k3d cluster
echo "Creating a new k3d cluster: rancher-$name_version..."
autok3s create --provider k3d --name rancher-$name_version --master 1 --worker 3
if [ $? -ne 0 ]; then
  echo "Failed to create the k3d cluster."
  exit 1
fi

# Switch to the new context
autok3s kubectl config use-context k3d-rancher-$name_version
export KUBECONFIG=~/.autok3s/.kube/config

# Ensure KUBECONFIG is set correctly
if [ ! -f "$KUBECONFIG" ]; then
  echo "KUBECONFIG file not found: $KUBECONFIG"
  exit 1
fi

# Create namespaces for cert-manager and Rancher if they don't exist
echo "Creating namespaces..."
kubectl create namespace cert-manager || echo "Namespace cert-manager already exists."
kubectl create namespace cattle-system || echo "Namespace cattle-system already exists."

# Wait for namespaces to be created
wait_for_namespace cert-manager
wait_for_namespace cattle-system

# Install cert-manager
echo "Installing cert-manager..."
cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  chart: cert-manager
  repo: https://charts.jetstack.io
  set:
    crds.enabled: "true"
  targetNamespace: cert-manager
  version: 1.15.3
EOF

# Wait for the cert-manager install Pod to complete
wait_for_helm_pod "helm-install-cert-manager" "kube-system"

# Step to update /etc/hosts with the Traefik LoadBalancer IP
echo "Getting Traefik LoadBalancer IP..."
traefik_ip=$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$traefik_ip" ]; then
  echo "Failed to get Traefik LoadBalancer IP."
  exit 1
fi

# Set hostname to match the Rancher hostname format
hostname="rancher-$name_version.rancher.test"

echo "Adding Traefik IP ($traefik_ip) to /etc/hosts as $hostname..."

# Backup existing /etc/hosts file before making changes
sudo cp /etc/hosts /etc/hosts.backup

# Add the IP and custom domain to /etc/hosts (e.g., rancher-v2-9-2.rancher.test)
sudo sed -i "/$hostname/d" /etc/hosts
echo "$traefik_ip $hostname" | sudo tee -a /etc/hosts

echo "Traefik IP added to /etc/hosts: $traefik_ip $hostname"

# Install Rancher using the provided version
echo "Installing Rancher..."
cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: rancher
  namespace: kube-system
spec:
  chart: rancher
  repo: https://releases.rancher.com/server-charts/latest
  set:
    hostname: rancher-$name_version.rancher.test
    bootstrapPassword: Passw0rd
    replicas: 1
  targetNamespace: cattle-system
  version: $version
EOF

# Wait for the Rancher install Pod to complete
wait_for_helm_pod "helm-install-rancher" "kube-system"

# Show IP addresses of the created VMs
show_vm_ips "${vm_names[@]}"

# Final confirmation
echo "Rancher $version installation complete on k3d cluster rancher-$name_version."
