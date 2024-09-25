# spin-up-rancher

This script automates the installation of Rancher in a K3s/k3d cluster using KVM/QEMU as the virtualization provider. It sets up a NAT network, creates VMs for the Rancher server, and launches the Rancher application along with cert-manager for handling certificates.

## Prerequisites

Before using the script, ensure that you have the following:

- A Linux machine with `bash`, `curl`, `wget`, and `apt-get`.
- Sufficient privileges to install packages and manage virtualization with `sudo`.
- Docker installed to create and manage containers as part of the K3d setup.

## Features

- Checks and installs `autok3s` if it's not already installed.
- Checks and installs KVM, QEMU, and necessary virtualization tools.
- Downloads and prepares Ubuntu Cloud Images for VM creation.
- Automatically handles the creation and configuration of VMs with cloud-init support for automated setup.
- Sets up a NAT network for the VMs.
- Installs and configures `cert-manager` on the K3s cluster.
- Installs a specified version of Rancher along with a Traefik load balancer for accessing the Rancher UI.
- Adds the Traefik IP to the system's `/etc/hosts` file for DNS resolution.
- Displays the IP addresses assigned to the created VMs.

## Usage

### Clone the Repository

If you haven't cloned the repository containing this script yet, do so using:

```bash
git clone <repository-url>
cd <repository-directory>
```

### Run the Script

Make sure to give execution permissions to the script:

```bash
chmod +x <script-name>.sh
```

Then execute the script by providing the desired Rancher version as an argument:

```bash
./<script-name>.sh <rancher-version>
```

Where `<rancher-version>` is the version of Rancher you want to install (e.g., `v2.9.2`).

### Example

To install Rancher version `v2.9.2`, run:

```bash
./install_rancher.sh v2.9.2
```

## Configuration

You can customize the VM configurations by editing the `vm_configs` array within the script. 

```bash
vm_configs=(
  "rancher-vm1 4096 2 20"  # VM name, RAM (MB), CPU count, Disk size (GB)
  "rancher-vm2 4096 2 20"
  "rancher-vm3 4096 2 20"
)
```

This allows you to set different specifications as per your system capabilities and requirements.

## Important Notes

- Ensure your system supports hardware virtualization (VT-x or AMD-V).
- After the installation completes, check the output for the IP of the VMs and the Rancher UI, along with access details.
- If you encounter issues, verify logs and installation statuses of the VMs and Kubernetes components to diagnose problems.
