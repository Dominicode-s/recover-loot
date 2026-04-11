# Recover Loot

A mod for **Road to Vostok** that saves your inventory when you die and lets you recover it by returning to your death location.

## Features

- **Death Stash**: When you die, all inventory and equipped gear is saved to disk
- **Pickup Spawning**: Return to the same map and find your items scattered at your death location
- **Single Stash**: Only the most recent death is kept — new deaths overwrite the old stash
- **Permadeath Respected**: No stash is saved on permadeath maps (Apartments, Terminal)
- **New Game Clean**: Stash is automatically cleared when starting a new character
- **MCM Support**: Configure via Mod Configuration Menu, or works standalone with defaults

## Installation

1. Download the latest `Recover-Loot.vmz` from [Releases](https://github.com/Dominicode-s/recover-loot/releases)
2. Place it in your game's `mods/` folder
3. (Optional) Install [Mod Configuration Menu](https://modworkshop.net/mod/55827) for in-game settings

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Enable Mod | On | Toggle the mod on/off |
| Show Hint Message | On | Show a message when entering a map with a stash nearby |

## Compatibility

- **Pure autoload** — no script overrides, works alongside any other mod
- Gracefully handles unknown items (skips them)
- Falls back to local config if MCM is not installed

## How It Works

1. You die → mod captures your full inventory + equipment + death position
2. You respawn and enter the same map → items spawn as pickups at your death location
3. Pick up your items → stash is cleared
4. If you die again before recovering → old stash is overwritten
