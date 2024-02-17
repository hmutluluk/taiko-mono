// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/
//
//   Email: security@taiko.xyz
//   Website: https://taiko.xyz
//   GitHub: https://github.com/taikoxyz
//   Discord: https://discord.gg/taikoxyz
//   Twitter: https://twitter.com/taikoxyz
//   Blog: https://mirror.xyz/labs.taiko.eth
//   Youtube: https://www.youtube.com/@taikoxyz

pragma solidity 0.8.24;

import "../test/DeployCapability.sol";
import "../contracts/L1/gov/TaikoTimelockController.sol";
import "../contracts/signal/SignalService.sol";

contract AuthorizeRelayer is DeployCapability {
    uint256 public privateKey = vm.envUint("PRIVATE_KEY");
    address public sharedSignalService = vm.envAddress("SHARED_SIGNAL_SERVICE");
    address[] public relayers = vm.envAddress("RELAYERS", ",");

    function run() external {
        require(relayers.length != 0, "invalid relayers");

        vm.startBroadcast(privateKey);

        SignalService signalService = SignalService(sharedSignalService);

        for (uint256 i; i < relayers.length; ++i) {
            signalService.authorizeRelayer(relayers[i], true);
        }

        vm.stopBroadcast();
    }
}
