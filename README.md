# Detect Hardware

A lightweight hardware detection and server inventory tool for Linux dedicated servers.

`detect-hardware` collects and reports detailed hardware, firmware, storage, RAID, network, and health information from Linux servers in a clean inventory format.

## Features

- System manufacturer, model, serial number and UUID detection
- Operating system and kernel information
- Motherboard / baseboard details
- BIOS and firmware information
- CPU model, socket, core and thread count
- RAM capacity, DIMM slot usage and memory module details
- Hardware RAID controller detection
- RAID level and RAID state reporting
- Disk and physical drive inventory
- SMART / disk health information
- Network IP, gateway and DNS detection
- Power supply status detection on supported servers
- Clean and readable CLI output

## Example Output

```text
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
```

## Requirements

The script may require the following Linux tools depending on the hardware:

```bash
dmidecode
lshw
lscpu
lsblk
smartctl
storcli / perccli / megacli
iproute2
```

On Ubuntu/Debian:

```bash
apt update
apt install -y dmidecode lshw smartmontools pciutils iproute2
```

For Broadcom / LSI MegaRAID controllers, install `storcli` or a compatible RAID management utility.

## Usage

Clone the repository:

```bash
git clone https://github.com/USERNAME/detect-hardware.git
cd detect-hardware
```

Make the script executable:

```bash
chmod +x detect-hardware.sh
```

Run as root:

```bash
sudo ./detect-hardware.sh
```

Root privileges are recommended because some hardware, DMI, RAID and SMART information may not be available to normal users.

## Supported Hardware

This tool is designed mainly for Linux dedicated servers and bare-metal environments.

Tested or intended use cases include:

- Supermicro servers
- AMD Ryzen / EPYC based dedicated servers
- Hardware RAID servers
- Broadcom / LSI MegaRAID controllers
- NVMe and SATA/SAS disks
- Linux rescue environments
- Provisioning and inventory systems

## Notes

Some values depend on server hardware, BIOS support and installed vendor tools.

For example:

- RAID details may require `storcli`, `perccli` or `megacli`
- Disk health may require `smartctl`
- PSU status may depend on IPMI/DMI support
- Some serial numbers may be hidden or unavailable depending on the system

## Security Notice

The output may contain sensitive information such as:

- Server serial number
- UUID
- Disk serial numbers
- IP address
- Gateway
- DNS configuration

Do not share raw output publicly unless sensitive values are removed.

## License

MIT License
