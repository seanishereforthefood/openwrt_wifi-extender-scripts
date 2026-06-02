## Overview

**openwrt-wifi-extender.sh** is an interactive OpenWrt script that configures your device to operate as a Wi-Fi client (STA mode). It scans available wireless networks, filters by signal strength, and sets up your OpenWrt device to connect to an upstream Wi-Fi network—effectively allowing it to use Wi-Fi as its uplink for LAN/WAN ports.

This script was created with the assistance of AI. 

## Features

- **Network Scanning**: Automatically discovers and displays all visible Wi-Fi networks sorted by signal strength
- **Signal Filtering**: Configurable signal strength threshold to filter out weak networks (default: -85 dBm)
- **DFS Channel Detection**: Identifies and marks DFS channels that may require CAC wait times
- **Security Support**: Handles WPA3, WPA2, WPA, WEP, and open networks
- **Channel Management**: Automatically configures radios to non-DFS channels during scanning to avoid CAC delays
- **Interactive Configuration**: User-friendly menu-driven interface for selecting and configuring networks
- **Connection Verification**: Checks wireless connection, network status, and internet reachability after setup
- **Configuration Backup**: Saves and restores original wireless configuration
- **Debug Mode**: Optional debug logging for troubleshooting
- **Lightweight**: Pure shell implementation with proper numeric comparison for signal strength

## Usage

```bash
./openwrt-wifi-extender.sh [OPTIONS]

Options:
  -s, --no-filter           Disable signal strength filtering
  -S, --signal-threshold N  Set custom signal threshold (default: -85 dBm)
  -d, --debug              Enable debug mode
  -h, --help               Show help message

