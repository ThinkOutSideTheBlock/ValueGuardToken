// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

//needed imports lines to be added (OZ and Contracts interfaces)
//need to be complete
// ═══════════════════════════════════════════════════════════
// CUSTOM ERRORS
// ═══════════════════════════════════════════════════════════
//need to be complete
// ═══════════════════════════════════════════════════════════
// TREASURY CONTROLLER CONTRACT
// ═══════════════════════════════════════════════════════════
contract TreasuryController is ReentrancyGuard, Pausable, AccessControl {
    //math/safemath to be imported (might be)
    // ─── Role Constants ─────────────────────────────────────
    // ─── Protocol Constants ─────────────────────────────────
    // ─── Immutables ─────────────────────────────────────────
    // ─── State Variables ────────────────────────────────────
    // ─── Events ─────────────────────────────────────────────
    // ─── Constructor ────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    // CORE MINT/REDEEM OPERATIONS
    // ═══════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Receive ETH for gas option payouts
     */
    receive() external payable {
        //tobecomplete
    }

    //this one might need fallback as well
}
