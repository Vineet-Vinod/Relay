# Relay

Relay is a voice-first mobile SSH client and terminal emulator that lets developers work with agents and remote terminals directly from their phone. We built an iPhone MVP that combines secure device connectivity, a phone-native terminal, and voice-based Agent Calls so users can code, debug, and manage development workflows without needing a laptop nearby.

## Overview

Current agentic coding workflows usually assume you have a laptop nearby. On a phone, you often have to choose between limited control and a frustrating typing experience.

Relay is built around the idea that a phone can be a great interface for control-heavy developer workflows if the experience is designed for it. It combines remote device connectivity, a phone-native terminal, and voice-based agent interaction into a single app.

## Why we built it

We spend a lot of time prompting agents to design features, implement tests, and debug issues. Existing tools made this possible from a laptop, but not in a way that felt natural on a phone.

We built Relay to explore a better workflow: one where developers can code from anywhere using just their phone, without giving up control.

## Features

- **Voice-first Agent Calls** for interacting with coding agents without heavy typing
- **Phone-native terminal experience** designed around touch and glide typing
- **Multiple tabs and parallel workflows** for working across tasks more efficiently
- **Device connectivity built in** with support for Tailscale and a simplified WireGuard-based setup
- **Secure remote access** using SSH for encrypted communication between devices

## How it works

Relay connects your phone to your development machine so you can control coding workflows remotely. For users already in the Tailscale ecosystem, Relay can integrate with their existing setup. For new users, Relay also provides a simpler VPN-based path to connect devices quickly.

Once connected, users can work through a terminal interface and launch Agent Calls to interact with coding agents using voice, which better matches the strengths of a phone.

## Built with

- Swift
- Xcode
- Apple SDKs
- Tailscale integration
- WireGuard-based VPN flow
- SSH

## Status

Relay is currently an MVP built for **iPhone and Mac**.

## What’s next

- Polish the iPhone experience
- Improve first-time setup
- Continue hardening the connectivity flow
- Launch on the App Store
- Expand to Android
- Support connections to more than just Macs
