// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PixelTurf
/// @notice A shared 64x64 pixel canvas. Anyone can place a tile; nobody, not
///         even the deployer, can erase one. There is no owner, no admin, no
///         Ownable, no reset/clear/batch/paint-many, no selfdestruct, no
///         upgradeability and no ETH handling. `placeTile` is the only function
///         that writes tile state and it performs a fixed number of writes
///         (one packed tile slot + one cooldown slot), with no loop.
/// @dev Colour model
///      The palette has 16 entries, indices 0..15. Index 0 is RESERVED as the
///      blank/white "never painted" colour: all storage starts at zero, so a
///      tile that has never been painted reads as 0. A deliberate paint with
///      colour 0 is indistinguishable from an unpainted tile. The practical
///      painting palette is therefore 1..15.
contract PixelTurf {
    /// @notice Canvas width in tiles.
    uint16 public constant WIDTH = 64;
    /// @notice Canvas height in tiles.
    uint16 public constant HEIGHT = 64;
    /// @notice Minimum time between two placements by the same address.
    uint64 public constant COOLDOWN = 30 seconds;
    /// @notice Number of valid colour indices (0..15).
    uint8 public constant PALETTE_SIZE = 16;

    /// @dev Total number of tiles on the canvas.
    uint256 private constant TOTAL = 4096;

    /// @dev Flat, packed canvas. Index = y * WIDTH + x. `uint8` elements are
    ///      packed 32-per-storage-slot, so writing one tile touches exactly one
    ///      slot regardless of how full the canvas is.
    uint8[WIDTH * HEIGHT] private _tiles;

    /// @notice Timestamp of each address' most recent placement. Keyed by the
    ///         caller (msg.sender) only; there is no way to write this for an
    ///         arbitrary address.
    mapping(address => uint64) public lastPlacedAt;

    /// @notice Emitted on every successful placement.
    /// @param player The address that placed the tile (indexed).
    /// @param x Tile column, 0..WIDTH-1.
    /// @param y Tile row, 0..HEIGHT-1.
    /// @param color Palette index, 0..PALETTE_SIZE-1.
    event TilePlaced(address indexed player, uint16 x, uint16 y, uint8 color);

    /// @notice Coordinates are outside the canvas.
    error OutOfBounds(uint16 x, uint16 y);
    /// @notice Colour index is not in the palette.
    error InvalidColor(uint8 color);
    /// @notice The caller is still cooling down.
    error CooldownActive(uint64 nextAllowedAt);

    /// @notice Paint a single tile at (x, y) with the given palette colour.
    /// @dev This is the only function that writes tile state. It performs two
    ///      storage writes and never loops.
    function placeTile(uint16 x, uint16 y, uint8 color) external {
        if (x >= WIDTH || y >= HEIGHT) revert OutOfBounds(x, y);
        if (color >= PALETTE_SIZE) revert InvalidColor(color);

        uint64 last = lastPlacedAt[msg.sender];
        uint64 nextAt = last + COOLDOWN;
        if (last != 0 && block.timestamp < nextAt) {
            revert CooldownActive(nextAt);
        }

        _tiles[uint256(y) * uint256(WIDTH) + x] = color;
        lastPlacedAt[msg.sender] = uint64(block.timestamp);

        emit TilePlaced(msg.sender, x, y, color);
    }

    /// @notice Read a single tile. Unpainted tiles read as 0.
    function getTile(uint16 x, uint16 y) external view returns (uint8) {
        if (x >= WIDTH || y >= HEIGHT) revert OutOfBounds(x, y);
        return _tiles[uint256(y) * uint256(WIDTH) + x];
    }

    /// @notice Read an entire row (64 tiles) in one call.
    function getRow(uint16 y) external view returns (bytes memory row) {
        if (y >= HEIGHT) revert OutOfBounds(0, y);
        uint256 base = uint256(y) * uint256(WIDTH);
        row = new bytes(WIDTH);
        for (uint256 i = 0; i < WIDTH; ++i) {
            row[i] = bytes1(_tiles[base + i]);
        }
    }

    /// @notice Read a rectangular region in one call.
    /// @param x0 Left column of the region.
    /// @param y0 Top row of the region.
    /// @param w Region width in tiles.
    /// @param h Region height in tiles.
    function getRegion(uint16 x0, uint16 y0, uint16 w, uint16 h)
        external
        view
        returns (bytes memory region)
    {
        uint256 ux = uint256(x0);
        uint256 uy = uint256(y0);
        uint256 uw = uint256(w);
        uint256 uh = uint256(h);
        if (ux + uw > WIDTH || uy + uh > HEIGHT) revert OutOfBounds(x0, y0);

        region = new bytes(uw * uh);
        uint256 k = 0;
        for (uint256 r = 0; r < uh; ++r) {
            uint256 base = (uy + r) * uint256(WIDTH) + ux;
            for (uint256 c = 0; c < uw; ++c) {
                region[k++] = bytes1(_tiles[base + c]);
            }
        }
    }

    /// @notice Read the whole canvas (4096 bytes) in one eth_call.
    function getCanvas() external view returns (bytes memory canvas) {
        canvas = new bytes(TOTAL);
        for (uint256 i = 0; i < TOTAL; ++i) {
            canvas[i] = bytes1(_tiles[i]);
        }
    }

    /// @notice The timestamp at which `player` may next place a tile.
    function nextAllowedAt(address player) external view returns (uint64) {
        return lastPlacedAt[player] + COOLDOWN;
    }
}
