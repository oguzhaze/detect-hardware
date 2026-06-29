# Detect Hardware

A lightweight server inventory and hardware detection script for Linux dedicated servers.

Detect Hardware prints a clean hardware inventory report including system information, BIOS/firmware, CPU, memory, RAID status, disk health, network configuration and power supply information.

It is designed for bare-metal Linux servers, dedicated servers, rescue environments and provisioning systems.

## Features

- System manufacturer, model, serial number and UUID detection
- Operating system and kernel information
- Package update status
- Motherboard / baseboard information
- BIOS version, release date and firmware mode
- Chassis serial and asset tag information
- CPU model, socket count, cores and threads
- RAM capacity, DIMM slot usage and memory module details
- Hardware RAID and software RAID detection
- RAID level and RAID state reporting
- Physical disk detection behind MegaRAID controllers
- SMART disk health, temperature, wear and power-on information
- IPv4 address, gateway and DNS detection
- Power supply information from SMBIOS and IPMI where available
- Clean and readable CLI output

## Example Output

    ============================================================
                      SERVER INVENTORY (hardware)
    ============================================================

    --- System ---
      Manufacturer:    Supermicro
      Product/Model:   AS -3015MR-H8TNR
      Serial Number:   XXXXXXXX
      UUID:            XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX

    --- Operating System ---
      OS:              Ubuntu 24.04.4 LTS
      Kernel:          6.8.0-124-generic
      Updates:         up to date (0 pending); package lists refreshed 4h ago

    --- Motherboard (baseboard) ---
      Manufacturer:    Supermicro
      Model:           H13SRD-F
      Serial Number:   XXXXXXXX

    --- BIOS / Firmware ---
      Vendor:          American Megatrends International, LLC.
      BIOS Version:    1.9
      Release Date:    05/12/2026
      BIOS Revision:   5.35
      Firmware Mode:   UEFI

    --- Chassis ---
      Type:            Other
      Serial Number:   XXXXXXXX
      Asset Tag:       Chassis Asset Tag

    --- CPU ---
      Model:           AMD Ryzen 9 7900 12-Core Processor
      Sockets:         1
      Cores/Threads:   12 / 24
      Microcode:       0xa60120c
      Max Speed:       5450 MHz

    --- Memory (RAM) ---
      Total (OS):      62 GB
      DIMM slots:      2 populated / 4 total
      Installed modules:
        DIMMA2    32 GB    DDR5    4800 MT/s   PN: HMCG88MEBEA081N      SN: XXXXXXXX
        DIMMB2    32 GB    DDR5    4800 MT/s   PN: HMCG88MEBEA081N      SN: XXXXXXXX

    --- Storage / RAID ---
      RAID type:       Hardware RAID
      Controller:      Broadcom / LSI MegaRAID 12GSAS/PCIe Secure SAS38xx
      RAID level:      RAID 0
      RAID state:      Degraded / rebuilding

    --- Disks ---
        /dev/sda   MR9540-8i                  1.7T      ?      SN: XXXXXXXX
        -- physical disks behind RAID controller --
        slot 4     Micron_7450_MTFD           960 GB    raid   SN: XXXXXXXX
        slot 5     Micron_7450_MTFD           960 GB    raid   SN: XXXXXXXX
        Physical disks detected: 2

    --- Disk health (SMART) ---
      2/2 disk(s) PASSED
      Disk 1 (megaraid,4): Micron_7450_MTFD
        Health: OK
        Temp: 39°C  Wear: 2%
      Disk 2 (megaraid,5): Micron_7450_MTFD
        Health: OK
        Temp: 39°C  Wear: 2%

    --- Network ---
      IPv4:            192.0.2.10/29
      Gateway:         192.0.2.1
      DNS:             1.1.1.1,8.8.8.8

    --- Power supply ---
      PSU1     PWS-2K20A-1R         2200 W   Present, OK
      PSU2     PWS-2K20A-1R         2200 W   Present, OK

    ============================================================

## Requirements

The script works on Linux systems and should be run as root for full hardware details.

Recommended packages for Ubuntu/Debian:

    apt update
    apt install -y dmidecode smartmontools pciutils iproute2 util-linux ipmitool curl wget

Main tools used by the script:

    dmidecode
    smartctl
    lsblk
    lscpu
    lspci
    ip
    resolvectl
    ipmitool
    storcli / storcli2 / perccli / megacli

## How to Run

There are three common ways to run Detect Hardware:

- Direct execution without cloning the repository
- Download and run manually
- Clone the repository and run the script

Root privileges are recommended because DMI, SMART, RAID and hardware details may not be fully visible to normal users.

## Direct Execution

Run directly with curl:

    curl -fsSL https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh | sudo bash

Run directly with wget:

    wget -qO- https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh | sudo bash

Run directly without automatic StorCLI installation:

    curl -fsSL https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh | sudo NO_INSTALL=1 bash

## Download and Run

Download the script:

    wget -O inventory.sh https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh

Make it executable:

    chmod +x inventory.sh

Run it:

    sudo ./inventory.sh

Save the output to a file:

    sudo ./inventory.sh > server-inventory.txt

## Clone and Run

Clone the repository:

    git clone https://github.com/oguzhaze/detect-hardware.git
    cd detect-hardware

Make the script executable:

    chmod +x inventory.sh

Run the script:

    sudo ./inventory.sh

Save the output:

    sudo ./inventory.sh > server-inventory.txt

## StorCLI Installation

For Broadcom / LSI MegaRAID controllers, the script uses StorCLI to read RAID level, virtual drive state and physical disk details.

The default StorCLI package used by this project is:

    https://github.com/oguzhaze/detect-hardware/raw/refs/heads/main/storcli_007.3703.0000.0000_all.deb

If a hardware RAID controller is detected and no compatible RAID CLI is found, the script can automatically download and install StorCLI on .deb / dpkg based systems.

Automatic StorCLI installation is triggered when running:

    sudo ./inventory.sh

To disable automatic StorCLI installation:

    NO_INSTALL=1 sudo ./inventory.sh

Manual StorCLI installation:

    wget -O /tmp/storcli.deb "https://github.com/oguzhaze/detect-hardware/raw/refs/heads/main/storcli_007.3703.0000.0000_all.deb"
    sudo dpkg -i /tmp/storcli.deb || sudo apt-get -f install -y

After manual installation, run the inventory script again:

    sudo ./inventory.sh

Use a custom StorCLI package URL:

    STORCLI_DEB_URL="https://github.com/oguzhaze/detect-hardware/raw/refs/heads/main/storcli_007.3703.0000.0000_all.deb" sudo ./inventory.sh

## Usage Examples

Basic inventory check:

    sudo ./inventory.sh

Run without installing StorCLI automatically:

    NO_INSTALL=1 sudo ./inventory.sh

Run and save output:

    sudo ./inventory.sh > server-inventory.txt

Run from rescue mode:

    apt update
    apt install -y dmidecode smartmontools pciutils iproute2 util-linux curl wget
    wget -O inventory.sh https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh
    chmod +x inventory.sh
    sudo ./inventory.sh

Direct execution and save output:

    curl -fsSL https://raw.githubusercontent.com/oguzhaze/detect-hardware/main/inventory.sh | sudo bash > server-inventory.txt

## RAID Support

The script can detect both software RAID and hardware RAID.

Supported RAID detection methods include:

- Linux software RAID using mdadm / /proc/mdstat
- Broadcom / LSI MegaRAID controllers
- StorCLI / StorCLI2
- PercCLI
- MegaCLI
- SMART passthrough for physical disks behind MegaRAID controllers

If a hardware RAID controller is detected and no RAID CLI is found, the script can automatically install Broadcom StorCLI on .deb / dpkg based systems.

## SMART / Disk Health

Disk health information is collected with smartctl.

Depending on the disk and controller type, the script may show:

- SMART health status
- Disk temperature
- SSD wear percentage
- Power-on hours
- Available spare
- Reallocated sectors or grown defects
- Physical disks behind RAID controller

Root access is required for complete SMART details.

## Power Supply Information

Power supply data may be collected from:

- SMBIOS / DMI Type 39
- IPMI sensors through ipmitool
- IPMI DCMI power readings

Power supply information depends on server model, BIOS/BMC support and installed tools.

## Supported Use Cases

This project is useful for:

- Dedicated server inventory
- Bare-metal provisioning
- Rescue system checks
- Datacenter hardware verification
- RAID status checks
- Disk health reporting
- Server delivery validation
- Support ticket diagnostics
- Asset documentation

## Tested / Intended Hardware

The script is mainly intended for Linux dedicated servers such as:

- Supermicro servers
- AMD Ryzen dedicated servers
- AMD EPYC servers
- Hardware RAID based servers
- Broadcom / LSI MegaRAID systems
- NVMe, SATA and SAS disk systems

## Repository Files

    detect-hardware/
    ├── inventory.sh
    ├── storcli_007.3703.0000.0000_all.deb
    └── README.md

## Notes

Some information may not be available on all systems.

For example:

- Serial numbers may require root access
- DMI information requires dmidecode
- SMART health requires smartmontools
- Hardware RAID details may require storcli, perccli or megacli
- PSU health may require ipmitool and BMC/IPMI support
- Some virtual machines may not expose real hardware details

## Security Notice

The output may contain sensitive server information.

Before sharing the output publicly, remove or mask:

- Server serial number
- UUID
- Chassis serial number
- Disk serial numbers
- Memory serial numbers
- Public IP address
- Gateway
- DNS configuration

Example:

    Serial Number: XXXXXXXX
    UUID: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    IPv4: 192.0.2.10/29

## License

MIT License
