# Pixel Turf: A Canvas Nobody Can Wipe

A shared 64x64 pixel canvas on **Base Sepolia**. Anyone can place a coloured tile, everyone is rate-limited by the same on-chain cooldown, and nobody (not a script, not the host, not the deployer) can erase or reset the board.

Built for Road to Devcon VIII, problem "Pixel Turf".

## Deployment

| Item | Value |
|---|---|
| Network | Base Sepolia (chain ID 84532) |
| Contract | [`0x5b24c2AE617b25EeeAC5e0cB258ECcBCc07B6d9A`](https://sepolia.basescan.org/address/0x5b24c2AE617b25EeeAC5e0cB258ECcBCc07B6d9A) |
| Deploy tx | [`0x47d45e4d1ab240ce27681b58c45c2d986c7ac74654f159b75128db3ea75afaf1`](https://sepolia.basescan.org/tx/0x47d45e4d1ab240ce27681b58c45c2d986c7ac74654f159b75128db3ea75afaf1) |
| Deployment block | `47984584` |
| Deployer | `0xfF74D8F79A71c53B6f17a019c93D0999cAB23a0A` |
| Canvas | 64 x 64 tiles (`WIDTH = 64`, `HEIGHT = 64`, 4,096 tiles) |
| Cooldown | 30 seconds per address (`COOLDOWN`) |
| Palette | 16 colours (`PALETTE_SIZE = 16`), `uint8` index |

Machine-readable record: [`deployments/base-sepolia.json`](deployments/base-sepolia.json).

Smoke test on the deployed contract: `placeTile(0,0,1)` tx `0x1f7b76113fcc09ea13e8a41f1ee6fc3c79f783d33a1a4c73c364e0cb2136408f` (block `47985302`), `getTile(0,0) = 1`, and an immediate second call reverts with `CooldownActive`.

## Design rules

- **No owner, no admin.** No `Ownable`, no fee, no `payable`, no `withdraw`, no batch/reset/clear function.
- **One write path.** `placeTile(uint16 x, uint16 y, uint8 color)` is the only function that writes tile state.
- **Fair pacing.** The cooldown is stored per `msg.sender` and enforced inside the contract. The UI cannot bypass it.
- **Constant-cost placement.** One packed tile slot write plus one cooldown slot write, no loop over the canvas. The test suite measures the first placement at 75,458 gas and the 1000th at 53,926 gas.
- **Cheap full-canvas reads.** The page loads the board with `getCanvas()`, never one read per tile.
- **Live board.** An open page picks up new placements without a reload.

## Contract (`src/PixelTurf.sol`)

| Item | Detail |
|---|---|
| Write | `placeTile(uint16 x, uint16 y, uint8 color)` |
| Storage | flat `uint8[WIDTH * HEIGHT]`, index `y * WIDTH + x` |
| Cooldown storage | `mapping(address => uint64) lastPlacedAt`, keyed by `msg.sender` |
| Errors | `OutOfBounds(uint16 x, uint16 y)`, `CooldownActive(uint64 nextAllowedAt)`, `InvalidColor(uint8)` |
| Event | `event TilePlaced(address indexed player, uint16 x, uint16 y, uint8 color)` |
| Reads | `getTile(x, y)`, `getRow(y)`, `getRegion(x0, y0, w, h)`, `getCanvas()`, `nextAllowedAt(address)`, `lastPlacedAt(address)` |
| Constants | `WIDTH`, `HEIGHT`, `COOLDOWN`, `PALETTE_SIZE` |

Placement order: bounds check, colour check, cooldown check against `lastPlacedAt[msg.sender]`, then the single tile write, the timestamp write and the event. Painting over an existing tile is allowed by design; nothing can clear a tile.

## Frontend (`ui/`)

| Concern | Implementation |
|---|---|
| Chain | `baseSepolia` (84532), `ui/src/App.tsx` |
| Initial load | `getCanvas()` |
| Live updates | `getLogs` polling every 3 s after the initial load |
| Cooldown display | `nextAllowedAt(address)` read from the contract |
| Stack | React 19, Vite 6, TypeScript 5, viem 2, wagmi 2, @tanstack/react-query 5, HTML Canvas |

Environment variables for the UI are listed in `ui/.env.example`.

## Trust model

| Attack | Result |
|---|---|
| Script spams placements from one address | Reverts with `CooldownActive` after the first tile. |
| Many addresses | Each still obeys the same cooldown, no address gets extra pace. |
| Out-of-range coordinates | Reverts with `OutOfBounds`. |
| Host or deployer wipes the board | No owner, admin, reset or clear function exists. The deployer has no special powers (tested). |
| Placement cost grows with canvas fill | Gas is flat (tested, first vs 1000th placement). |

## Acceptance checklist

| # | Check | Where |
|---|---|---|
| 1 | Frontend targets Base Sepolia | `ui/src/App.tsx` |
| 2 | No credentials in tracked files | `.env` git-ignored, only `.env.example` placeholders |
| 3 | Cooldown against `msg.sender` | `src/PixelTurf.sol`, `test_Cooldown_KeyedByMsgSender_CannotPlaceForAnother` |
| 4 | Bounds check | `src/PixelTurf.sol`, `test_Revert_OutOfBounds_At_And_Past_Edge` |
| 5 | Only `placeTile` writes tile state | `test_OnlyPlaceTileWritesTileState`, `test_ABI_ExposesOnlyExpectedFunctions_NoEraseOrAdmin` |
| 6 | Event carries coordinates | `test_Event_TilePlaced_CarriesPlayerAndCoords` |
| 7 | Initial load avoids one read per tile | `getCanvas()` in `ui/src/App.tsx` |
| 8 | No loop in placement | `test_Gas_PlaceTileIsFlat_FirstVsThousandth` |
| 9 | Live updates without reload | `getLogs` polling in `ui/src/App.tsx` |
| 10 | Cooldown read from contract | `nextAllowedAt` in `ui/src/App.tsx` |

## Run it locally

Requires [Foundry](https://book.getfoundry.sh/) and Node 20.12+.

```bash
git clone --recurse-submodules https://github.com/pratikshakalbhor/devcon8-ps2-pixel-turf.git
cd devcon8-ps2-pixel-turf

forge build
forge test -vv            # 16 tests

cd ui
cp .env.example .env.local   # contract address, deployment block, RPC
npm install
npm run dev
```

## Deploy your own

```bash
cp .env.example .env         # PRIVATE_KEY, BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
set -a; source <(tr -d '\r' < .env); set +a
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
cast code <address> --rpc-url $BASE_SEPOLIA_RPC_URL | head -c 20   # expect 0x6080...
```

`PixelTurf` takes no constructor arguments. `.env` is git-ignored. Never commit a private key, mnemonic, API key or key-bearing RPC URL.

## Tests

`forge test -vv`: 16 tests passing. They cover per-sender cooldown (including that nobody can place for another address), bounds and colour reverts, the single write path, an ABI check that no erase or admin function exists, the event payload, region reads, overwrite behaviour, and flat placement gas.

## Security notes

- No owner, no admin, no upgrade path. The only write is the permissionless, cooldown-limited `placeTile`.
- No credentials are committed.