# PixelTurf

A shared, immutable 64x64 pixel canvas deployed on **Base Sepolia**. Anyone can place a tile, but nobody — including the deployer — can erase anything.

- Canvas dimensions: **64x64**
- Cooldown: **30 seconds** per address
- Palette: **16 colors** (index 0 is reserved as the blank/never-painted color)

## Deployment

| Field | Value |
|---|---|
| Network | Base Sepolia (chain ID 84532) |
| Address | [0x5b24c2AE617b25EeeAC5e0cB258ECcBCc07B6d9A](https://sepolia.basescan.org/address/0x5b24c2AE617b25EeeAC5e0cB258ECcBCc07B6d9A) |
| Deploy tx | [0x47d45e4d1ab240ce27681b58c45c2d986c7ac74654f159b75128db3ea75afaf1](https://sepolia.basescan.org/tx/0x47d45e4d1ab240ce27681b58c45c2d986c7ac74654f159b75128db3ea75afaf1) |
| Deployment block | 47984584 |
| Canvas | 64 x 64 |
| Cooldown | 30 seconds |

A machine-readable copy lives in [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

## How to paint
1. Connect a wallet (injected or Coinbase Wallet).
2. Switch to **Base Sepolia** if prompted.
3. Pick a color from the palette (0–15).
4. Click a tile on the canvas to select (x,y).
5. Click **Paint** to call `placeTile(x, y, color)`.
6. Wait for confirmation. After placing, you must wait 30s before painting again (tracked via `nextAllowedAt(address)`).

## Why nobody can wipe it
- **Single write path:** `placeTile` is the only function that writes tile state. No `reset`, `clear`, `batch`, admin, or owner functions.
- **No admin powers:** The contract has no owner; deployer has no special privileges.
- **Immutable by design:** No `selfdestruct`, no upgradeability, no ability to erase to a prior state.
- **Per-address cooldown:** Prevents spam while keeping the canvas open to everyone.
- **Flat gas placement:** Each placement touches a fixed number of storage slots (no loops over canvas) — gas stays constant regardless of fill.
- **Event-sourced history:** All placements emit `TilePlaced(player, x, y, color)` so state is fully reconstructable.

## Running the frontend locally
1. Copy `ui/.env.example` to `ui/.env` and fill values (address, deployment block, RPC). Use public RPC `https://sepolia.base.org` if needed.
2. Install dependencies (if needed): `cd ui && npm install`
3. Dev server: `cd ui && npx vite`
4. Build: `cd ui && npx vite build`
5. Preview: `cd ui && npx vite preview`

## Forge
- Run all tests: `forge test -vv`
