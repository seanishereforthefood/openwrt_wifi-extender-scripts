## Overview

**openwrt-wifi-extender.sh** is an interactive OpenWrt script that configures your device to operate as a Wi-Fi client (STA mode) as a Wi-Fi bridge/relay. It scans available wireless networks, filters by signal strength, and sets up your OpenWrt device to connect to an upstream Wi-Fi network—effectively allowing it to use Wi-Fi as its uplink for LAN/WAN ports.

The script was designed for use if one wants to avoide using LuCi, there are many turtotials that can be found to produce similar results using that.

This script was created with the assistance of AI. 

## Features

- **Network Scanning**: Automatically discovers and displays all visible Wi-Fi networks sorted by signal strength
- **Signal Filtering**: Configurable signal strength threshold to filter out weak networks (default: -85 dBm)
- **DFS Channel Detection**: Identifies and marks DFS channels that may require CAC wait times
- **Security Support**: Handles WPA3, WPA2, WPA, WEP, and open networks
- **Channel Management**: Automatically configures radios to non-DFS channels during scanning to avoid CAC delays
- **Connection Verification**: Checks wireless connection, network status, and internet reachability after setup
- **Configuration Backup**: Saves and restores original wireless configuration
- **Debug Mode**: Optional debug logging for troubleshooting

## Usage

# Note: Connecting directly to the OpenWRT device via LAN port is recomended. 

```bash
./openwrt-wifi-extender.sh [OPTIONS]

Options:
  -s, --no-filter           Disable signal strength filtering
  -S, --signal-threshold N  Set custom signal threshold (default: -85 dBm)
  -d, --debug              Enable debug mode
  -h, --help               Show help message
```

## Background and history

About two years ago I picked up a few Linksys MX4300s at a good price hoping to see OpenWRT release on them. Once it was available I started work on turning these into wifi clients that can provide wired connections to remote locations of my house. Initially I had a very basic workflow setup using docs found on openwrt.org (linked below). I started working on a script for fun and then decided to play around with Claude to expand on function. I think it's pretty neat. Nothing special but it works. 

## References 

https://openwrt.org/docs/guide-user/network/wifi/wifiextenders/bridgedap
https://openwrt.org/docs/guide-user/network/wifi/basic

