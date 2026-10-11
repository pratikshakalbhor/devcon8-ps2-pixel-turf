// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PixelTurf} from "../src/PixelTurf.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        PixelTurf pixelTurf = new PixelTurf();
        vm.stopBroadcast();
        console.log("PixelTurf deployed to:", address(pixelTurf));
    }
}
