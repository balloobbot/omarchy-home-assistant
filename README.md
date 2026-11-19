# Home Assistant for Omarchy

Control Home Assistant from the Omarchy bar. View live entity states, camera pictures, media volume, and lock controls in one panel.

## Requirements

- Omarchy with the Quickshell plugin system.
- Python 3. The helper uses only the standard library.
- Avahi (`avahi-browse`) for server discovery on your local network.
- `xdg-open` and a browser for Home Assistant login.
- Recommended: `secret-tool` from `libsecret` and an unlocked desktop keyring.

## Install

```sh
omarchy plugin add https://github.com/balloobbot/omarchy-home-assistant.git --enable
```

Open the Home Assistant icon in the bar. Select a discovered server and complete login in your browser. Then select entities from Suggestions or search by name. The panel supports up to 16 selected entities.

## Use

The settings icon opens entity management. Use the server icon at the top of that view to switch servers. Switching servers clears the selected entities.

Entity states stream over a WebSocket connection. The plugin reconnects automatically. Camera pictures update every five seconds while the main panel is open.

Lights and other supported entities have toggle controls. Locks have separate lock and unlock buttons. Media players have volume controls. Scenes, scripts, and buttons can be activated from the panel.

Keyboard shortcuts while the panel has focus:

| Key | Action |
| --- | --- |
| Up / Down | Select a row |
| Enter | Activate the selected row |
| A | Open entity management |
| S | Open server selection |
| / | Focus search in entity management |
| X | Remove the selected entity in entity management |
| + / - | Adjust the selected media player's volume |
| M | Toggle mute for the selected media player |
| R | Reload suggestions or search for servers again |
| Escape | Return to the main panel or close it |

## Credentials and settings

Login uses Home Assistant's browser authorization flow. Refresh tokens are stored in the desktop keyring. If the keyring is unavailable, the helper stores credentials in files with mode `0600` under `$XDG_STATE_HOME/omarchy-home-assistant` (normally `~/.local/state/omarchy-home-assistant`).

Server selection and entity IDs are stored in your Omarchy shell settings. Log out from the server selection view to remove stored credentials.

## Update

```sh
omarchy plugin update paulus.home-assistant
```

## Development

```sh
uv venv
uv run --no-project python -I tests/test_plugin.py
omarchy-plugin-validate .
```

## License

MIT. Home Assistant names and logos belong to their respective owners.
